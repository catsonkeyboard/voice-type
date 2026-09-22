using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using VoiceType.Interop;
using VoiceType.Models;

namespace VoiceType.UI.Controls;

/// <summary>
/// 点击后捕获下一次带修饰键的按键，作为新的全局快捷键
/// （对应 macOS KeyComboRecorder；Alt 组合经 Key.SystemKey 到达）。
/// </summary>
public partial class KeyComboRecorder : UserControl
{
    public static readonly DependencyProperty ComboProperty = DependencyProperty.Register(
        nameof(Combo), typeof(KeyCombo), typeof(KeyComboRecorder),
        new PropertyMetadata(KeyCombo.Default, OnComboChanged));

    public KeyCombo Combo
    {
        get => (KeyCombo)GetValue(ComboProperty);
        set => SetValue(ComboProperty, value);
    }

    public event Action<KeyCombo>? ComboChanged;

    private bool _capturing;

    public KeyComboRecorder()
    {
        InitializeComponent();
        PreviewKeyDown += OnPreviewKeyDown;
        Loaded += (_, _) => UpdateLabel();
    }

    private static void OnComboChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var control = (KeyComboRecorder)d;
        if (!control._capturing)
            control.UpdateLabel();
    }

    private void UpdateLabel() =>
        Label.Text = Combo?.Display ?? "";

    private void OnButtonClick(object sender, RoutedEventArgs e)
    {
        if (_capturing)
            return;
        _capturing = true;
        Label.Text = "按下新快捷键…（Esc 取消）";
        CaptureButton.Focus();
        Focusable = true;
        Keyboard.Focus(CaptureButton);
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (!_capturing)
            return;
        e.Handled = true;

        if (e.Key == Key.Escape)
        {
            EndCapture(null);
            return;
        }

        // 修饰键本身按下时继续等待
        Key key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt
            or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin)
            return;

        var modifiers = Keyboard.Modifiers;
        var hotkeyModifiers = HotkeyModifiers.None;
        if (modifiers.HasFlag(ModifierKeys.Control))
            hotkeyModifiers |= HotkeyModifiers.Control;
        if (modifiers.HasFlag(ModifierKeys.Alt))
            hotkeyModifiers |= HotkeyModifiers.Alt;
        if (modifiers.HasFlag(ModifierKeys.Shift))
            hotkeyModifiers |= HotkeyModifiers.Shift;
        if (modifiers.HasFlag(ModifierKeys.Windows))
            hotkeyModifiers |= HotkeyModifiers.Win;

        if (hotkeyModifiers == HotkeyModifiers.None)
        {
            Label.Text = "必须包含 Ctrl/Alt/Shift/Win 修饰键…";
            System.Media.SystemSounds.Beep.Play();
            return;
        }

        uint vk = (uint)KeyInterop.VirtualKeyFromKey(key);
        EndCapture(KeyCombo.Create(hotkeyModifiers, vk));
    }

    private void EndCapture(KeyCombo? combo)
    {
        _capturing = false;
        if (combo is not null)
        {
            Combo = combo;
            ComboChanged?.Invoke(combo);
        }
        UpdateLabel();
    }
}
