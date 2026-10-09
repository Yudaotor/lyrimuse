package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// healthcheck 里的「后台服务」和「文件夹权限」两项。healthcheck 是单独起的一次性进程,不经过常驻服务,
// 别的检查项在服务没注册、或它要写的位置写不进时照样全绿;这两种情况下歌词一定出不来,所以都报 fail。
// Swift 侧同一套文件夹判据在 LyrimuseCore 的 HomeFolderAccess,两处一起改。见 15 章决策 31。

// engineLaunchdLabel 是常驻服务的 launchd label,Swift 侧对应 LyrimuseIdentity.engineLaunchdLabel。
const engineLaunchdLabel = "com.lyrimuse.collector"

type launchdJobState struct {
	registered bool
	// stateKnown 为假:print 成功了但认不出顶层 state 字段。
	stateKnown bool
	running    bool
	pid        int
	// lastExit 是 `last exit code` 的原值(如 `78: EX_CONFIG`、`(never exited)`),没有这个字段时为空。
	lastExit string
}

// parseLaunchdPrint 解析 `launchctl print gui/<uid>/<label>` 的退出码和输出。只认行首恰好一个 tab 的字段:
// 嵌套结构里也有 `state = active`,同一层还有 `job state = …`。Swift 侧对应 LaunchdPrintParser。
func parseLaunchdPrint(exitCode int, out string) launchdJobState {
	if exitCode != 0 {
		return launchdJobState{}
	}
	job := launchdJobState{registered: true}
	for _, line := range strings.Split(out, "\n") {
		key, value, ok := topLevelLaunchdField(line)
		if !ok {
			continue
		}
		switch key {
		case "state":
			job.stateKnown = true
			job.running = value == "running"
		case "pid":
			job.pid, _ = strconv.Atoi(value)
		case "last exit code":
			job.lastExit = value
		}
	}
	return job
}

// topLevelLaunchdField 只去掉一个 tab:嵌套行剩下的键名还带着 tab,跟任何字段名都对不上。别对键名 TrimSpace。
func topLevelLaunchdField(line string) (key, value string, ok bool) {
	rest, indented := strings.CutPrefix(line, "\t")
	if !indented {
		return "", "", false
	}
	key, value, ok = strings.Cut(rest, " = ")
	return key, strings.TrimSpace(value), ok
}

// launchctlPrint 跑一次 `launchctl print`,返回退出码和 stdout。单测换成假的。
var launchctlPrint = func(target string) (int, string) {
	out, err := exec.Command("/bin/launchctl", "print", target).Output()
	var exitErr *exec.ExitError
	switch {
	case err == nil:
		return 0, string(out)
	case errors.As(err, &exitErr):
		return exitErr.ExitCode(), string(out)
	default:
		return -1, ""
	}
}

func engineServiceHealthItem(job launchdJobState) healthCheckItem {
	item := healthCheckItem{Name: "后台服务"}
	switch {
	case !job.registered:
		item.Status = healthFail
		item.Detail = "歌词引擎没有注册到系统(launchd),常驻服务没在跑:在设置 › 播放器 › 歌词引擎点「启用」;启用不了先看「文件夹权限」那一项"
	case !job.stateKnown:
		item.Status = healthWarn
		item.Detail = "注册了,但认不出 launchctl print 的输出,不知道在不在跑"
	case job.running:
		item.Status = healthOK
		item.Detail = fmt.Sprintf("在运行(pid %d)", job.pid)
	default:
		item.Status = healthFail
		item.Detail = "注册了但没在运行"
		if job.lastExit != "" {
			item.Detail += "(上次退出码 " + job.lastExit + ")"
		}
		if strings.HasPrefix(job.lastExit, "78") {
			item.Detail += ";78 多半是日志文件写不进,先看「文件夹权限」那一项"
		}
	}
	return item
}

type homeFolderTarget struct {
	path string
	// launchdPlist:除了归自己、写得进,还不许组和其他用户可写,launchd 拒收这样的 plist。
	launchdPlist bool
}

// homeFolderTargets 是常驻服务要写的几处位置,跟 Swift 侧 HomeFolderAccess.targets 同一份清单。
func homeFolderTargets() []homeFolderTarget {
	var targets []homeFolderTarget
	if dir := configDir(); dir != "" {
		targets = append(targets, homeFolderTarget{path: filepath.Dir(dir)}, homeFolderTarget{path: dir})
	}
	home, homeErr := os.UserHomeDir()
	if homeErr == nil {
		targets = append(targets, homeFolderTarget{path: filepath.Join(home, "Library/LaunchAgents")})
	}
	if logPath := logFilePath(); logPath != "" {
		targets = append(targets, homeFolderTarget{path: filepath.Dir(logPath)}, homeFolderTarget{path: logPath})
	}
	if homeErr == nil {
		targets = append(targets, homeFolderTarget{
			path: filepath.Join(home, "Library/LaunchAgents", engineLaunchdLabel+".plist"), launchdPlist: true})
	}
	return targets
}

// folderAccessProblem 返回一处位置的问题,没问题或不存在时返回空串(还没建过是正常的)。
func folderAccessProblem(t homeFolderTarget, uid int) string {
	info, err := os.Stat(t.path)
	if err != nil {
		return ""
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return ""
	}
	if int(st.Uid) != uid {
		owner := "uid " + strconv.Itoa(int(st.Uid))
		if u, err := user.LookupId(strconv.Itoa(int(st.Uid))); err == nil {
			owner = u.Username
		}
		return "属于 " + owner
	}
	if syscall.Access(t.path, 2) != nil { // W_OK
		return "没有写入权限"
	}
	if mode := info.Mode().Perm(); t.launchdPlist && mode&0o022 != 0 {
		return fmt.Sprintf("其他用户也可写(%o),launchd 拒绝加载", mode)
	}
	return ""
}

func folderAccessHealthItem(targets []homeFolderTarget, uid int, userName string) healthCheckItem {
	var problems, fixes []string
	for _, t := range targets {
		problem := folderAccessProblem(t, uid)
		if problem == "" {
			continue
		}
		problems = append(problems, t.path+" "+problem)
		quoted := "'" + strings.ReplaceAll(t.path, "'", `'\''`) + "'"
		if strings.HasPrefix(problem, "其他用户也可写") {
			fixes = append(fixes, "chmod 644 "+quoted)
		} else {
			fixes = append(fixes, fmt.Sprintf("sudo chown -R '%s':staff %s && chmod u+rwX %s", userName, quoted, quoted))
		}
	}
	if len(problems) == 0 {
		return healthCheckItem{Name: "文件夹权限", Status: healthOK, Detail: fmt.Sprintf("%d 处位置都归当前用户、可写", len(targets))}
	}
	return healthCheckItem{Name: "文件夹权限", Status: healthFail, Detail: strings.Join(problems, ";") +
		"。歌词引擎装不上或起不来。在终端里运行:" + strings.Join(fixes, " ; ")}
}

func currentUserName() string {
	if u, err := user.Current(); err == nil {
		return u.Username
	}
	return os.Getenv("USER")
}
