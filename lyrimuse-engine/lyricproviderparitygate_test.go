package main

import (
	"sync"
	"time"
)

// pairGate 让源并发发出的两个请求一起到:单数个到的等下一个到了才放行。并发的两路里先回来的那一路接着往下走时,另一路
// 发没发出去就不看调度的快慢了,两条路记下的请求才能逐条比。等不到搭档 3 秒后返回 false,假服务器这时回一个错误
// 状态让用例红掉(配对写错了的场景不能悄悄退成不配对)。
type pairGate struct {
	mu      sync.Mutex
	waiting chan struct{}
}

func (g *pairGate) arrive() bool {
	g.mu.Lock()
	if g.waiting != nil {
		close(g.waiting)
		g.waiting = nil
		g.mu.Unlock()
		return true
	}
	ch := make(chan struct{})
	g.waiting = ch
	g.mu.Unlock()
	select {
	case <-ch:
		return true
	case <-time.After(3 * time.Second):
		g.mu.Lock()
		if g.waiting == ch {
			g.waiting = nil
		}
		g.mu.Unlock()
		return false
	}
}

// pairGateTimedOut:等不到搭档时假服务器回的应答。
var pairGateTimedOut = parityReply{status: 599, body: "pair gate: the paired request never arrived"}
