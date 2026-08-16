# dmgbuild 的设置文件。package.sh 在 dmgbuild 可用时用它出美化 DMG,不可用时退回
# 原来的 hdiutil 路径(功能完全一样,只是没有背景图和图标摆位)。
#
# 为什么现在能做美化了:package.sh 里原来那段注释说"带背景图、图标摆好位置的窗口需要
# 挂可写镜像再用 AppleScript 让 Finder 设窗口 bounds 和图标坐标,那是有副作用的 GUI
# 自动化,故意不做" —— 这个前提对 dmgbuild 不成立。它直接往镜像里写 .DS_Store
# (自己实现了那个格式),全程不启动 Finder、不挂 GUI、无副作用。
#
# 保持跟原来 hdiutil 完全一致的两个语义:HFS+ 文件系统、UDZO 只读压缩格式。
#
# 由 package.sh 通过环境变量传入:
#   LYRIMUSE_DMG_APP        要装进去的 .app 路径
#   LYRIMUSE_DMG_VOLNAME    卷名(主包/Intel 包不同,同时挂载才分得清)
#   LYRIMUSE_DMG_BACKGROUND 背景图路径(make_dmg_background.swift 生成的 tiff)
import os

application = os.environ["LYRIMUSE_DMG_APP"]
_app_name = os.path.basename(application)

# ⚠️ dmgbuild 的 `filesystem`/`format` 必须跟 hdiutil 那条路径一致,否则同一个版本
# 用不用 dmgbuild 出来的产物特性不同(兼容性、体积),那种差异排查起来很费劲。
filesystem = "HFS+"
format = "UDZO"

volume_name = os.environ["LYRIMUSE_DMG_VOLNAME"]

files = [application]
symlinks = {"Applications": "/Applications"}

badge_icon = None
background = os.environ["LYRIMUSE_DMG_BACKGROUND"]

# 窗口尺寸跟背景图尺寸严格相等(660x400),否则背景图会被平铺或裁掉。
# window_rect 是 ((左, 下), (宽, 高)),原点在屏幕左下;图标坐标系原点却在窗口左上 ——
# 这两套坐标不一致是 dmgbuild 配置里最容易摆错的一处。
window_rect = ((200, 180), (660, 400))
icon_size = 128
# 跟 make_dmg_background.swift 里的 appIconCenter/applicationsCenter 一致。
icon_locations = {
    _app_name: (180, 170),
    "Applications": (480, 170),
}

default_view = "icon-view"
show_icon_preview = False
# 侧边栏/工具栏/状态栏全关:这个窗口只有两个图标,任何 chrome 都只是噪音。
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 14
