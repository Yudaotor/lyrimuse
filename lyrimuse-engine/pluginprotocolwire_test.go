package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"slices"
	"sync"
	"time"
)

// 跑一致性用例的夹具:内存里的一条连接(两根单向管道、按行分帧)、照脚本演的一头(ppScripted)、
// 把两头接起来跑一个用例的 ppRun。不起子进程、不连网络、不等真实时间。
//
// 接真实现的办法:写一个 ppActor 把被测对象接到 ppConn 上,另一头仍用 ppScripted。
//   - 测 plugin-host:适配器在 conn 上跑 plugin-host 的主循环(conn.in 当 stdin、conn.out 当 stdout),
//     用例里 engine 发的每一步由 ppScripted 照发,host 该回的每一行由它核对。
//   - 测引擎端(pluginRPCClient 加两段式适配器):适配器按 c.Fixture 布置(清单、脚本、假上游 HTTP、要报的上限),
//     按 c.Drive 在对应的步骤之前驱动引擎(start / resolve / cancel / stop / releaseHttp),Observe 那一步核对引擎的结论;
//     用例里 host 发的每一步由 ppScripted 照发。
// 只跑 c.subjectIncludes(那一头) 的用例:别的用例里那一头是故意不守协议的,真实现演不出来。

// ppConn 是连接的一头:in 读对端写过来的字节,out 写给对端。真实现的适配器直接拿这两个当 stdin / stdout;
// 照脚本演的一头用 next / writeLine 按行收发。
type ppConn struct {
	in  *io.PipeReader
	out *io.PipeWriter

	wmu       sync.Mutex
	startPump sync.Once
	lines     chan []byte // 对端的每一行(去掉行尾换行),对端关掉输出时关闭
}

// ppPipe 建一条连接,返回引擎那一头和 plugin-host 那一头。
func ppPipe() (engine, host *ppConn) {
	toHostR, toHostW := io.Pipe()
	toEngineR, toEngineW := io.Pipe()
	engine = &ppConn{lines: make(chan []byte, 256), in: toEngineR, out: toHostW}
	host = &ppConn{lines: make(chan []byte, 256), in: toHostR, out: toEngineW}
	return engine, host
}

// pump 把读到的字节切成行。行长不设上限:上限是被测实现的事,夹具要能把超长行原样送到。
func (c *ppConn) pump() {
	defer close(c.lines)
	r := bufio.NewReaderSize(c.in, 64<<10)
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 && line[len(line)-1] == '\n' {
			c.lines <- line[:len(line)-1]
		} else if len(line) > 0 {
			c.lines <- line
		}
		if err != nil {
			return
		}
	}
}

// writeLine 发一行,整行一次写完,并发调用不会互相穿插。
func (c *ppConn) writeLine(line []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	_, err := c.out.Write(append(slices.Clone(line), '\n'))
	return err
}

// closeWrite 关掉自己的输出:对端读到 EOF。可以重复调。
func (c *ppConn) closeWrite() { c.out.Close() }

// abort 把两个方向都掐断,卡在读写上的一头立刻返回。
func (c *ppConn) abort(err error) {
	c.out.CloseWithError(err)
	c.in.CloseWithError(err)
}

// next 取对端的下一行;ok 为 false 是对端关了输出。第一次调用时起读循环。
func (c *ppConn) next(ctx context.Context) (line []byte, ok bool, err error) {
	c.startPump.Do(func() { go c.pump() })
	select {
	case line, ok = <-c.lines:
		return line, ok, nil
	case <-ctx.Done():
		return nil, false, ctx.Err()
	}
}

// ppClock 是用例里的时钟。Clock 那一步由两头各走到一次,同一步只算一次。
// 被测实现用注入的时钟时读 total;被测实现用真实时钟时把 realTime 置真,拨多少就真等多少。
type ppClock struct {
	realTime bool

	mu      sync.Mutex
	done    map[int]bool
	elapsed time.Duration
}

func (k *ppClock) advance(step int, d time.Duration) {
	k.mu.Lock()
	if k.done == nil {
		k.done = map[int]bool{}
	}
	first := !k.done[step]
	if first {
		k.done[step] = true
		k.elapsed += d
	}
	k.mu.Unlock()
	if first && k.realTime {
		time.Sleep(d)
	}
}

func (k *ppClock) total() time.Duration {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.elapsed
}

// ppActor 在连接的一头把一个用例演完。返回 nil 表示这一头看到的对话符合用例。
type ppActor interface {
	Play(ctx context.Context, c *ppCase, role string, conn *ppConn, clock *ppClock) error
}

// ppScripted 照脚本演:轮到自己就把那一步实例化发出去,轮到对端就等一行来核对。
// 对端多发、少发、发错、顺序不对(unordered 之外)都算不符。Steps 非空时演的是它,不是用例自己的脚本(测夹具本身用)。
type ppScripted struct {
	Steps []ppStep
}

func (a ppScripted) Play(ctx context.Context, c *ppCase, role string, conn *ppConn, clock *ppClock) error {
	steps := c.Steps
	if a.Steps != nil {
		steps = a.Steps
	}
	vars := ppVars{}
	fx := &c.values
	ambient := c.ambient()
	for i := range steps {
		s := &steps[i]
		where := fmt.Sprintf("第 %d 步", i+1)
		var err error
		switch kind := s.kind(); {
		case kind == "clock":
			clock.advance(i, time.Duration(s.Clock.AdvanceMs)*time.Millisecond)
		case kind == "observe":
			// 结论由参考模型核对(ppCheckCase);照脚本演的一头没有自己的结论可看。
		case s.From == role:
			err = ppSendStep(s, conn, vars, fx)
		default:
			err = ppExpectStep(ctx, s, conn, vars, fx, ambient)
		}
		if err != nil {
			return fmt.Errorf("%s(%s): %w", where, role, err)
		}
	}
	conn.closeWrite()
	for {
		line, ok, err := conn.next(ctx)
		if err != nil {
			return fmt.Errorf("脚本演完后等对端收尾(%s): %w", role, err)
		}
		if !ok {
			return nil
		}
		if !ppIsAmbient(line, ambient) {
			return fmt.Errorf("脚本演完之后对端又发来一行(%s): %s", role, ppBriefLine(line))
		}
	}
}

func ppSendStep(s *ppStep, conn *ppConn, vars ppVars, fx *ppFixtureValues) error {
	switch s.kind() {
	case "message":
		return ppSendPattern(s.pattern, conn, vars, fx)
	case "unordered":
		for _, p := range s.Unordered {
			if err := ppSendPattern(p, conn, vars, fx); err != nil {
				return err
			}
		}
		return nil
	case "raw":
		line, err := s.rawLine()
		if err != nil {
			return err
		}
		return conn.writeLine(line)
	case "close":
		conn.closeWrite()
		return nil
	}
	return fmt.Errorf("不会发这种步骤")
}

func ppSendPattern(p any, conn *ppConn, vars ppVars, fx *ppFixtureValues) error {
	v, _, err := ppInstantiate(p, vars, fx)
	if err != nil {
		return err
	}
	line, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return conn.writeLine(line)
}

func ppExpectStep(ctx context.Context, s *ppStep, conn *ppConn, vars ppVars, fx *ppFixtureValues, ambient []string) error {
	var remaining []any
	var wantRaw []byte
	switch s.kind() {
	case "message":
		remaining = []any{s.pattern}
	case "unordered":
		remaining = slices.Clone(s.Unordered)
	case "raw":
		var err error
		if wantRaw, err = s.rawLine(); err != nil {
			return err
		}
	}
	for {
		line, ok, err := conn.next(ctx)
		if err != nil {
			return fmt.Errorf("等对端: %w", err)
		}
		if s.Close {
			if !ok {
				return nil
			}
			if ppIsAmbient(line, ambient) {
				continue
			}
			return fmt.Errorf("对端该关掉输出,却发来 %s", ppBriefLine(line))
		}
		if !ok {
			return fmt.Errorf("对端关了输出,还在等它的消息")
		}
		if wantRaw != nil {
			if bytes.Equal(line, wantRaw) {
				return nil
			}
			return fmt.Errorf("要原样的一行 %s,收到 %s", ppBriefLine(wantRaw), ppBriefLine(line))
		}
		matched, mismatch := ppMatchAny(remaining, line, vars, fx)
		if matched < 0 {
			if ppIsAmbient(line, ambient) {
				continue
			}
			return fmt.Errorf("收到 %s: %w", ppBriefLine(line), mismatch)
		}
		remaining = slices.Delete(remaining, matched, matched+1)
		if len(remaining) == 0 {
			return nil
		}
	}
}

// ppMatchAny 拿一行去配 patterns 里的某一条,返回配上的下标;都配不上返回 -1 和第一条的不符原因。
func ppMatchAny(patterns []any, line []byte, vars ppVars, fx *ppFixtureValues) (int, error) {
	var v any
	if err := json.Unmarshal(line, &v); err != nil {
		return -1, fmt.Errorf("不是 JSON: %w", err)
	}
	var first error
	for i, p := range patterns {
		trial := maps.Clone(vars)
		err := ppMatch(p, v, true, trial, fx, "$")
		if err == nil {
			maps.Copy(vars, trial)
			return i, nil
		}
		if first == nil {
			first = err
		}
	}
	return -1, first
}

// ppIsAmbient:这一行是不是用例允许随时出现的通知。
func ppIsAmbient(line []byte, ambient []string) bool {
	var msg struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
	}
	if json.Unmarshal(line, &msg) != nil || msg.ID != nil {
		return false
	}
	return slices.Contains(ambient, msg.Method)
}

func ppBriefLine(line []byte) string {
	if len(line) > 200 {
		return fmt.Sprintf("%s…(共 %d 字节)", line[:200], len(line))
	}
	return string(line)
}

// ppRun 把两头接到一条连接上跑一个用例,返回各自的结果。一头出错就掐断连接,另一头不会一直等。
func ppRun(c *ppCase, engine, host ppActor) (engineErr, hostErr error, clock *ppClock) {
	return ppRunWithin(20*time.Second, c, engine, host, &ppClock{})
}

// ppRunWithin 同 ppRun,整个用例最多等 limit:一头在等一条永远不会来的消息时,到点按不符算。
func ppRunWithin(limit time.Duration, c *ppCase, engine, host ppActor, clock *ppClock) (engineErr, hostErr error, _ *ppClock) {
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	defer cancel()
	engineConn, hostConn := ppPipe()
	var wg sync.WaitGroup
	var once sync.Once
	play := func(a ppActor, role string, conn *ppConn, into *error) {
		defer wg.Done()
		*into = a.Play(ctx, c, role, conn, clock)
		if *into != nil {
			once.Do(func() {
				cancel()
				engineConn.abort(io.ErrClosedPipe)
				hostConn.abort(io.ErrClosedPipe)
			})
		}
	}
	wg.Add(2)
	go play(engine, ppEngine, engineConn, &engineErr)
	go play(host, ppHost, hostConn, &hostErr)
	wg.Wait()
	engineConn.abort(io.ErrClosedPipe)
	hostConn.abort(io.ErrClosedPipe)
	return engineErr, hostErr, clock
}

// ppFirstCause 从两头的结果里挑出先出的那个不符:被掐断连接带出来的那个错误不算。
func ppFirstCause(engineErr, hostErr error) error {
	secondary := func(err error) bool {
		return err == nil || errors.Is(err, context.Canceled) || errors.Is(err, io.ErrClosedPipe)
	}
	// 两头都卡在等对方(到点才结束)时,两个结果都是超时,报引擎那一头的。
	switch {
	case !secondary(engineErr):
		return engineErr
	case !secondary(hostErr):
		return hostErr
	case engineErr != nil:
		return engineErr
	}
	return hostErr
}
