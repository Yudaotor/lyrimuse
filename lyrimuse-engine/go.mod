module github.com/Yudaotor/lyrimuse/lyrimuse-engine

go 1.27.0

// 构建、测试用的 Go 工具链只在下面 toolchain 这一行定:两份 build.sh、scripts/commit-checks.sh、go-test-shards.py、
// go-mutate.py、各生成器调的 gofmt 和 CI 的 setup-go 都从这一行读,换版只改这里。
// GOTOOLCHAIN=auto(默认)下裸跑 go 命令也会切到这一版;GOTOOLCHAIN=local 会绕过它。
// 本机 PATH 上的 go1.21 产出的二进制缺 LC_UUID,AMFI 拒签、启动即死,症状像被测代码自己崩了,别用它编引擎和测试。
// 换版前核对:新版要求的最低 macOS 不高于 App 的 LSMinimumSystemVersion、darwin/amd64 仍是一级移植;
// 不同版本的 gofmt 对齐结果可能不同,换版后整个引擎目录用新版 gofmt -w 过一遍。见 15 章决策 126。
toolchain go1.27.4

// go 行跟 toolchain 行同一个小版本:更老的工具链(显式 GOTOOLCHAIN=go1.24.4 这类)一启动就报
// 「go.mod requires go >= …」,不会用旧工具链编出结果再在 Unicode 表、gofmt 对齐这类地方对不上。
// GODEBUG 默认值仍按 go1.22(TLS 不发后量子密钥交换等),换工具链不顺带改联网行为;工具链已删掉的几项
// (asynctimerchan、tls3des 等)不受这一行管。要换默认值单独改这一行,并真机实测各歌词源。
godebug default=go1.22
