package main

import (
	"context"
	"syscall"
	"time"
)

// dirWatchWake:等目录事件时多久醒一次看 ctx 有没有结束。只影响退出时多等多久,不影响收到事件的快慢。
const dirWatchWake = time.Second

// watchDirWrites 用 kqueue 盯一个目录:目录里有条目新建、删除、改名时往 out 里塞一个信号。「临时文件 + 改名」
// 的原子写落盘就是一次改名,所以盯目录而不盯文件本身(改名换上来的是新文件,盯着旧文件收不到事件)。
// out 要带缓冲;塞不进(上一个信号还没被取走)就丢,收到的一方自己去看到底哪个文件变了。
// 打不开目录或建不起 kqueue 时返回 false,调用方照旧靠定时器。ctx 结束后最多 dirWatchWake 退出。
func watchDirWrites(ctx context.Context, dir string, out chan<- struct{}) bool {
	fd, err := syscall.Open(dir, syscall.O_EVTONLY|syscall.O_CLOEXEC, 0)
	if err != nil {
		return false
	}
	kq, err := syscall.Kqueue()
	if err != nil {
		syscall.Close(fd)
		return false
	}
	var change syscall.Kevent_t
	syscall.SetKevent(&change, fd, syscall.EVFILT_VNODE, syscall.EV_ADD|syscall.EV_CLEAR)
	change.Fflags = syscall.NOTE_WRITE
	if _, err := syscall.Kevent(kq, []syscall.Kevent_t{change}, nil, nil); err != nil {
		syscall.Close(kq)
		syscall.Close(fd)
		return false
	}
	go func() {
		defer syscall.Close(fd)
		defer syscall.Close(kq)
		events := make([]syscall.Kevent_t, 4)
		wake := syscall.NsecToTimespec(int64(dirWatchWake))
		for ctx.Err() == nil {
			n, err := syscall.Kevent(kq, nil, events, &wake)
			if err == syscall.EINTR {
				continue
			}
			if err != nil {
				warnf("dirwatch: stopped watching dir=%s, falling back to the timer: %v", dir, err)
				return
			}
			if n > 0 {
				select {
				case out <- struct{}{}:
				default:
				}
			}
		}
	}()
	return true
}
