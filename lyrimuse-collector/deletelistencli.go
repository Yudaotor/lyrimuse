package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// `collector delete-listen -uts <秒> [-uts ...]`:从本地收听日志里删掉指定的几条。
//
// 给"本地已记录 N 首，连接后可补提交"那个清单上的删除按钮用 —— 用户看见里面有不想补
// 提交的条目(误记的、不想让它出现在 Last.fm 上的),得有办法拿掉。
//
// 为什么这件事必须由 collector 做,而不是 Swift 那边直接改文件:这份 jsonl 是 collector
// 的东西,它一边在往里**追加**(每首播完写一行),格式和折叠语义也都在这边(见 listenlog.go
// 和 pendingBackfillListens)。让另一个进程去读-改-写一个正在被追加的文件,是在自找竞态。
//
// 删除粒度是**整个 uts**,不是"只删那一行":同一个 uts 可能有收听行(t=l)、提交回执(t=s)、
// 隔离标记(t=q) 好几行。只删收听行会留下指向不存在收听的孤儿回执,那些回执还会继续参与
// pendingBackfillListens 的"已提交"判定,变成看不见摸不着的幽灵状态。
func runDeleteListenCLI(args []string) {
	fs := flag.NewFlagSet("delete-listen", flag.ExitOnError)
	var utsList utsFlag
	fs.Var(&utsList, "uts", "要删除的收听时间戳(Unix 秒),可重复,或用逗号分隔")
	asJSON := fs.Bool("json", true, "以 JSON 输出结果")
	// -config 跟其它一次性子命令一个形状。存在的理由不只是对称:一个会删用户数据的
	// 命令必须能在临时目录里被完整地端到端验证一遍,而不是只能拿真实日志试。
	cfgPath := fs.String("config", "", "配置文件路径(默认 ~/.config/lyrimuse/config.json)")
	if err := fs.Parse(args); err != nil {
		os.Exit(2)
	}
	if len(utsList) == 0 {
		fmt.Fprintln(os.Stderr, "delete-listen: 至少要给一个 -uts")
		os.Exit(2)
	}

	resolved := *cfgPath
	if resolved == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			fmt.Fprintf(os.Stderr, "delete-listen: 拿不到家目录: %v\n", err)
			os.Exit(1)
		}
		resolved = filepath.Join(home, ".config", clientName, "config.json")
	}
	// 跟 main() 用同一条路径规则。这条一次性子命令不会走到 main 里 initListenLog 那行
	// (它在 os.Args[1] 的提前分支里就 return 了),所以自己设一次。
	// ⚠️ **不能**调 initListenLog:那个会顺带跑一次 compactListenLog,把超限的老记录一并
	// 截掉 —— 用户点的是"删这一条",不该附带一次静默的历史清理。
	setListenLogPath(filepath.Join(filepath.Dir(resolved), clientName+"-listens.jsonl"))

	deleted, remaining, err := deleteListensByUTS(utsList)
	if err != nil {
		fmt.Fprintf(os.Stderr, "delete-listen: %v\n", err)
		os.Exit(1)
	}
	if *asJSON {
		_ = json.NewEncoder(os.Stdout).Encode(struct {
			Deleted   int `json:"deleted"`
			Remaining int `json:"remaining"`
		}{deleted, remaining})
	} else {
		fmt.Printf("deleted %d line(s), %d remaining\n", deleted, remaining)
	}
}

// utsFlag 支持 `-uts 1 -uts 2` 和 `-uts 1,2` 两种写法。
type utsFlag []int64

func (f *utsFlag) String() string { return fmt.Sprint(*f) }

func (f *utsFlag) Set(v string) error {
	for _, part := range strings.Split(v, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		n, err := strconv.ParseInt(part, 10, 64)
		if err != nil {
			return fmt.Errorf("%q 不是合法的时间戳", part)
		}
		// uts<=0 一律拒绝:日志里 uts 为 0 的行是坏数据,而"删掉所有坏数据"绝不该由一次
		// 「删这一条」的点击悄悄触发。
		if n <= 0 {
			return fmt.Errorf("时间戳必须为正数,收到 %d", n)
		}
		*f = append(*f, n)
	}
	return nil
}

// deleteListensByUTS 重写整份日志,丢掉这些 uts 的所有行。返回删掉几行、还剩几行。
//
// 整份重写 + tmp/rename,跟 compactListenLog 同一个套路(见那边注释):中途崩溃不会留下
// 半份日志。这个文件按设计是"只追加"的,删除是它唯一的例外路径,所以宁可整份重写也不
// 去做原地编辑。
func deleteListensByUTS(targets []int64) (deleted, remaining int, err error) {
	drop := make(map[int64]bool, len(targets))
	for _, u := range targets {
		drop[u] = true
	}

	lines := readListenLog()
	kept := make([]listenLogLine, 0, len(lines))
	for _, line := range lines {
		if drop[line.UTS] {
			deleted++
			continue
		}
		kept = append(kept, line)
	}
	if deleted == 0 {
		// 一条都没匹配上不是错误(界面上那条可能刚被别处删掉了),但也别白写一遍文件。
		return 0, len(lines), nil
	}

	listenLogMu.Lock()
	defer listenLogMu.Unlock()
	if listenLogPath == "" {
		return 0, 0, fmt.Errorf("收听日志路径未设置")
	}
	tmp := listenLogPath + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return 0, 0, fmt.Errorf("建临时文件失败: %w", err)
	}
	w := bufio.NewWriter(f)
	for _, line := range kept {
		data, err := json.Marshal(line)
		if err != nil {
			continue
		}
		if _, err := w.Write(append(data, '\n')); err != nil {
			f.Close()
			os.Remove(tmp)
			return 0, 0, fmt.Errorf("写临时文件失败: %w", err)
		}
	}
	if err := w.Flush(); err != nil {
		f.Close()
		os.Remove(tmp)
		return 0, 0, fmt.Errorf("刷新临时文件失败: %w", err)
	}
	f.Close()
	if err := os.Rename(tmp, listenLogPath); err != nil {
		os.Remove(tmp)
		return 0, 0, fmt.Errorf("替换日志失败: %w", err)
	}
	return deleted, len(kept), nil
}

// setListenLogPath 只设路径,不做压缩 —— 见 runDeleteListenCLI 里那段注释。
func setListenLogPath(path string) {
	listenLogMu.Lock()
	listenLogPath = path
	listenLogMu.Unlock()
}
