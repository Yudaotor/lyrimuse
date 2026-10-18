package main

// sqliteBatch 把造测试库的整份 SQL 放进一个事务、不等落盘:逐条自动提交时每条 INSERT 都要等一次 fsync。
func sqliteBatch(script string) string {
	return "PRAGMA synchronous=OFF;\nBEGIN;\n" + script + "COMMIT;\n"
}
