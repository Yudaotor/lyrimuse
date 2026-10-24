package main

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// 酷狗音乐的专辑动态封面:Apple、QQ、网易云三支都没给出动态封面时,看酷狗自己缓存的那份。酷狗放到一张有动态封面的专辑时,
// 把它存在容器里 `KGDynamicArtwork/<专辑 id>.mp4`(同目录 `<专辑 id>.jpg` 是首帧),专辑 id 跟它报给我们的那个
// (PlayerAlbumIDs,kugouPlayingSong)是同一个。画面是 3:4 竖幅、HEVC、无音轨、4~20 秒;有两种:中间是方形封面、上下是色带,
// 或者整幅是封面裁窄的一段、动画中途推近。引擎认出文件后拷进缓存目录(App 不读别的 App 的容器,会弹「想访问其他 App 的
// 数据」),动态封面地址写成 `kgmv:<专辑 id>`;App 读拷过来的那份,中段帧、首帧的中间正方形有一帧对上当前封面才用
// (MotionCoverIdentityVerified 为 false)。不联网,不进动态封面那张缓存表:酷狗放过之后文件才有,每次现看。
// 见 03 章决策 69。

// kugouMotionCoverScheme:动态封面地址里酷狗那一种的前缀,后面是酷狗专辑 id。App 侧按它认(KugouMotionCover)。
const kugouMotionCoverScheme = "kgmv:"

// kugouMotionStageDirName:缓存目录里放拷过来的酷狗动态封面的子目录,App 读同一处(KugouMotionCover.stageDirName)。
const kugouMotionStageDirName = "kugou-motion-covers"

// kugouMotionStageMax:拷过来的最多留几份,多了按修改时间删最旧的(一份 0.1~3 MB)。
const kugouMotionStageMax = 60

// kugouMotionVideoMaxBytes:超过这个大小的不拷(实测最大 2.7 MB)。
const kugouMotionVideoMaxBytes = 32 << 20

// kugouDynamicArtworkOverride 让单测把酷狗那个目录指到临时路径。空 = 用真实路径。
var kugouDynamicArtworkOverride string

func kugouDynamicArtworkDir() string {
	if kugouDynamicArtworkOverride != "" {
		return kugouDynamicArtworkOverride
	}
	return kugouContainerPath("Library/Application Support/com.kugou.mac.Music/KGDynamicArtwork")
}

// kugouMotionStagedPath:拷过来的那份。拿不到缓存目录为 ""。
func kugouMotionStagedPath(id string) string {
	if cacheDir() == "" {
		return ""
	}
	return filepath.Join(cacheFilePath(kugouMotionStageDirName), id+".mp4")
}

// kugouMotionCoverAlbum:这条记着的酷狗专辑 id,酷狗本机有它的动态封面视频时返回 id 和那个文件;没有、读不了为 ""。
func kugouMotionCoverAlbum(e enrichEntry) (id, file string) {
	id = e.PlayerAlbumIDs[kugouMusicBundleID]
	dir := kugouDynamicArtworkDir()
	if !playerSongIDOK(kugouMusicBundleID, id) || dir == "" {
		return "", ""
	}
	file = filepath.Join(dir, id+".mp4")
	if fi, err := os.Stat(file); err != nil || !fi.Mode().IsRegular() || fi.Size() == 0 || fi.Size() > kugouMotionVideoMaxBytes {
		return "", ""
	}
	return id, file
}

// stageKugouMotionCover:把酷狗那份拷进缓存目录(已有一样大的就不拷),拷完按 kugouMotionStageMax 删旧的。成了为 true。
func stageKugouMotionCover(id, src string) bool {
	dst := kugouMotionStagedPath(id)
	if dst == "" {
		return false
	}
	si, err := os.Stat(src)
	if err != nil {
		return false
	}
	if di, err := os.Stat(dst); err == nil && di.Size() == si.Size() {
		return true
	}
	b, err := os.ReadFile(src)
	if err != nil || int64(len(b)) != si.Size() {
		return false
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		noteFileErr("mkdir", filepath.Dir(dst), err)
		return false
	}
	if writeFileAtomic(dst, b) != nil {
		return false
	}
	pruneKugouMotionStage(filepath.Dir(dst), kugouMotionStageMax)
	return true
}

// pruneKugouMotionStage:目录里的 .mp4 多于 keep 份时,按修改时间删最旧的。
func pruneKugouMotionStage(dir string, keep int) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	type staged struct {
		path string
		mod  int64
	}
	var files []staged
	for _, e := range ents {
		if !strings.HasSuffix(e.Name(), ".mp4") {
			continue
		}
		if fi, err := e.Info(); err == nil && fi.Mode().IsRegular() {
			files = append(files, staged{filepath.Join(dir, e.Name()), fi.ModTime().UnixNano()})
		}
	}
	if len(files) <= keep {
		return
	}
	sort.Slice(files, func(i, j int) bool { return files[i].mod < files[j].mod })
	for _, f := range files[:len(files)-keep] {
		_ = os.Remove(f.path)
	}
}

// motionVerdictFromKugou:前面几支都没给出动态封面时看酷狗本机那份,返回有没有定论(同 motionVerdictFromAlbum):只有拷不过来时
// 没有定论,下一轮再试。checked:前面核出了「没有」(而不是根本没有可核的东西)—— 酷狗这边也没有时,前者记「核过、没有」,
// 后者整组清掉。
func (e *enrichEntry) motionVerdictFromKugou(checked bool) bool {
	id, file := kugouMotionCoverAlbum(*e)
	switch {
	case id != "":
		if !stageKugouMotionCover(id, file) {
			return false
		}
		e.recordMotionVerdict(kugouMotionCoverScheme+id, "", false)
	case checked:
		e.recordMotionVerdict("", "", false)
	default:
		e.clearMotionVerdict()
	}
	return true
}

// kugouMotionCoverUnasked:播到时值得再核一次的两种:对着现在这张封面核出「没有」,而酷狗本机后来有了这张专辑的动态封面
// (酷狗放过之后才下到本机);记着酷狗那份、拷过来的却没了(被删旧的删掉了),再拷一次。只看本机文件。
func kugouMotionCoverUnasked(e enrichEntry) bool {
	if e.MotionCoverFor != e.CoverURL {
		return false
	}
	switch {
	case e.MotionCoverChecked && e.MotionCoverURL == "":
		id, _ := kugouMotionCoverAlbum(e)
		return id != ""
	case strings.HasPrefix(e.MotionCoverURL, kugouMotionCoverScheme):
		id, _ := kugouMotionCoverAlbum(e)
		if id == "" || e.MotionCoverURL != kugouMotionCoverScheme+id {
			return false
		}
		_, err := os.Stat(kugouMotionStagedPath(id))
		return err != nil
	}
	return false
}
