#!/usr/bin/perl
# 把同目录那个 dylib 装进本进程并调它 —— 用 /usr/bin/perl 是因为这些 MediaRemote 私有接口
# 只对 Apple 平台二进制回话(理由见 nowplaying-clients.m 的头注)。
use strict;
use warnings;
use DynaLoader;

my $lib = shift @ARGV or die "usage: $0 /path/to/libnowplaying-clients.dylib [bundleID] [artwork|queue=N|watch=BUNDLE_ID|seek=SECONDS|rate-playing]\n";
my $bundle = shift @ARGV;
my $mode = shift @ARGV;      # 传 "artwork" 才带封面 —— 常规状态查询不该每拍背一张图;
                            # 传 "queue=N" 改为输出这个播放器的待播队列(当前这首 + 之后 N 首)
$ENV{LYRIMUSE_NOWPLAYING_BUNDLE} = $bundle if defined $bundle && length $bundle;
$ENV{LYRIMUSE_NOWPLAYING_ARTWORK} = 1 if defined $mode && $mode eq "artwork";
$ENV{LYRIMUSE_NOWPLAYING_QUEUE} = $1 if defined $mode && $mode =~ /^queue=(\d+)$/;
# 传 "watch=BUNDLE_ID" 改为常驻:盯那个 App 内嵌网页的 WebKit 媒体会话,变了才输出一行(bundleID 那一格留空)
$ENV{LYRIMUSE_NOWPLAYING_WATCH} = $1 if defined $mode && $mode =~ /^watch=(.+)$/;
# 传 "seek=SECONDS" 改为定向给 bundleID 那个 App 发一次「跳到第几秒」,输出一行结果
$ENV{LYRIMUSE_NOWPLAYING_SEEK} = $1 if defined $mode && $mode =~ /^seek=(\d+(?:\.\d+)?)$/;
# 兼容名单由调用方的共享播放器配置决定;默认状态查询不能继承外部遗留的开关。
delete $ENV{LYRIMUSE_NOWPLAYING_RATE_PLAYING};
$ENV{LYRIMUSE_NOWPLAYING_RATE_PLAYING} = 1 if defined $mode && $mode eq "rate-playing";

my $handle = DynaLoader::dl_load_file($lib, 0) or die "cannot load $lib\n";
my $symbol = DynaLoader::dl_find_symbol($handle, "nowplaying_clients")
  or die "symbol nowplaying_clients not found in $lib\n";
DynaLoader::dl_install_xsub("main::nowplaying_clients", $symbol);
no strict "refs";
&{"main::nowplaying_clients"}();
