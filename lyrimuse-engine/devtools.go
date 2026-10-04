package main

// devSubcommands:开发者手动跑的存量修数据子命令,名字 → 入口(参数是子命令名之后的那些)。
//
// 只有带 devtools 构建标签时,covercli.go / motionrecheckcli.go / resynclyricscli.go / crossalbumcli.go 的 init
// 才把它们登记进来(在 lyrimuse-engine 下 `go run -tags devtools . recheck-cover ...`);build.sh 编正式版
// 不带这个标签,发给用户的引擎里这张表是空的。这些命令默认只预演,-apply 才改缓存,而且要求常驻实例已停。
var devSubcommands = map[string]func(args []string){}
