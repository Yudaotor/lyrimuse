#!/usr/bin/perl
# 把同目录那个 dylib 装进本进程并调它 —— 用 /usr/bin/perl 是因为这些 MediaRemote 私有接口
# 只对 Apple 平台二进制回话(理由见 nowplaying-clients.m 的头注)。
use strict;
use warnings;
use DynaLoader;

my $lib = shift @ARGV or die "usage: $0 /path/to/libnowplaying-clients.dylib [bundleID]\n";
my $bundle = shift @ARGV;
my $artwork = shift @ARGV;   # 传 "artwork" 才带封面 —— 常规状态查询不该每拍背一张图
$ENV{LYRIMUSE_NOWPLAYING_BUNDLE} = $bundle if defined $bundle && length $bundle;
$ENV{LYRIMUSE_NOWPLAYING_ARTWORK} = 1 if defined $artwork && $artwork eq "artwork";

my $handle = DynaLoader::dl_load_file($lib, 0) or die "cannot load $lib\n";
my $symbol = DynaLoader::dl_find_symbol($handle, "nowplaying_clients")
  or die "symbol nowplaying_clients not found in $lib\n";
DynaLoader::dl_install_xsub("main::nowplaying_clients", $symbol);
no strict "refs";
&{"main::nowplaying_clients"}();
