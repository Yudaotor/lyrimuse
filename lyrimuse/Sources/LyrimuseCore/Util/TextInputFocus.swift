/// 键盘焦点所在的控件算不算输入框(触控栏「输入时收起」,见 17 章决策 59)。
///
/// 按辅助功能报的角色判:文本框(含搜索框)、多行文本、组合框算;密码框不算(系统在密码框里不给输入建议,收起只是白让位)。
/// 别的角色(网页区域、按钮、自绘编辑器只报出来的窗口 / 分组)一律不算:认不出就不动,别让用户在普通窗口里也看不到歌词。
public enum TextInputFocus {
    public static func isTextInput(role: String?, subrole: String?) -> Bool {
        guard subrole != "AXSecureTextField" else { return false }
        switch role {
        case "AXTextField", "AXTextArea", "AXComboBox": return true
        default: return false
        }
    }
}
