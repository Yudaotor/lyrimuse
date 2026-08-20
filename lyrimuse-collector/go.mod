module applemusic-nowplaying/collector

go 1.21

// 钉住构建/测试用的工具链版本,不只是靠 AGENTS.md 提醒「记得带 GOTOOLCHAIN=go1.24.4」。
//
// 这台机器上系统 Go 是 1.21,而它产出的**测试二进制**在当前 macOS 上直接被 dyld 拒绝
// (`missing LC_UUID load command` → abort trap),表现成一大片 FAIL,极容易被当成代码
// 问题排查(2026-08-20 就为此空转了几轮)。build.sh:137 早就显式设了
// GOTOOLCHAIN=go1.24.4(理由见 build.sh:123 的注释:1.21 产物缺 LC_UUID、AMFI 拒签),
// 但那只覆盖打包路径 —— 裸跑 `go test` / `go vet` 的人(或 agent)不会自动享受到。
//
// 有了这一行,GOTOOLCHAIN=auto(默认)下任何 go 命令都会自动切到 1.24.4,`go test ./...`
// 不带环境变量也能跑。AGENTS.md 里那条显式写法保留:它是 belt-and-suspenders,而且
// GOTOOLCHAIN=local 会绕过这一行。
toolchain go1.24.4
