package main

import (
	"context"
	"sync"
	"syscall"
	"time"
)

// dirWatchStopIdent:叫醒监听 goroutine 退出用的那个用户事件的标识。
const dirWatchStopIdent = 1

// watchDirWrites 用 kqueue 盯一个目录:目录里有条目新建、删除、改名时往 out 里塞一个信号。「临时文件 + 改名」
// 的原子写落盘就是一次改名,所以盯目录而不盯文件本身(改名换上来的是新文件,盯着旧文件收不到事件)。
// out 要带缓冲;塞不进(上一个信号还没被取走)就丢,收到的一方自己去看到底哪个文件变了。
// 打不开目录或建不起 kqueue 时返回 false,调用方照旧靠定时器。等事件时不定时醒:ctx 结束时触发一个用户事件叫它退出。
func watchDirWrites(ctx context.Context, dir string, out chan<- struct{}) bool {
	_, ok := startDirWatch(ctx, dir, out)
	return ok
}

// startDirWatch 同 watchDirWrites,另交回一个通道:监听 goroutine 退出、描述符都关掉之后关闭它。
func startDirWatch(ctx context.Context, dir string, out chan<- struct{}) (<-chan struct{}, bool) {
	fd, err := syscall.Open(dir, syscall.O_EVTONLY|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, false
	}
	kq, err := syscall.Kqueue()
	if err != nil {
		syscall.Close(fd)
		return nil, false
	}
	var vnode, stop syscall.Kevent_t
	syscall.SetKevent(&vnode, fd, syscall.EVFILT_VNODE, syscall.EV_ADD|syscall.EV_CLEAR)
	vnode.Fflags = syscall.NOTE_WRITE
	syscall.SetKevent(&stop, dirWatchStopIdent, syscall.EVFILT_USER, syscall.EV_ADD|syscall.EV_CLEAR)
	if _, err := syscall.Kevent(kq, []syscall.Kevent_t{vnode, stop}, nil, nil); err != nil {
		syscall.Close(kq)
		syscall.Close(fd)
		return nil, false
	}
	// 触发退出事件和关描述符互斥:关掉的描述符号可能已经被别的文件复用,不能再往它上面发 kevent。
	var closeMu sync.Mutex
	closed := false
	stopped := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
		case <-stopped:
			return
		}
		closeMu.Lock()
		defer closeMu.Unlock()
		if closed {
			return
		}
		var trigger syscall.Kevent_t
		syscall.SetKevent(&trigger, dirWatchStopIdent, syscall.EVFILT_USER, 0)
		trigger.Fflags = syscall.NOTE_TRIGGER
		_, _ = syscall.Kevent(kq, []syscall.Kevent_t{trigger}, nil, nil)
	}()
	go func() {
		defer func() {
			closeMu.Lock()
			closed = true
			syscall.Close(kq)
			syscall.Close(fd)
			closeMu.Unlock()
			close(stopped)
		}()
		events := make([]syscall.Kevent_t, 4)
		for {
			n, err := syscall.Kevent(kq, nil, events, nil)
			if err == syscall.EINTR {
				continue
			}
			if err != nil {
				warnf("dirwatch: stopped watching dir=%s, falling back to the timer: %v", dir, err)
				return
			}
			if ctx.Err() != nil {
				return
			}
			for _, ev := range events[:n] {
				if ev.Filter != syscall.EVFILT_VNODE {
					continue
				}
				select {
				case out <- struct{}{}:
				default:
				}
				break
			}
		}
	}()
	return stopped, true
}

// requestWatchFallback:请求循环盯得了目录时的兜底轮询间隔,目录事件万一漏了最晚这么久之后也会看到。
const requestWatchFallback = 10 * time.Second

// requestWakeups:请求文件循环的两个叫醒来源。盯着 dir,目录一变就从返回的通道收到信号;另配一个定时器,
// 盯得了时每 requestWatchFallback 一次,盯不了时按 poll。调用方负责 Stop 定时器。
func requestWakeups(ctx context.Context, dir string, poll time.Duration) (<-chan struct{}, *time.Ticker) {
	writes := make(chan struct{}, 1)
	interval := poll
	if watchDirWrites(ctx, dir, writes) {
		interval = requestWatchFallback
	}
	return writes, time.NewTicker(interval)
}
