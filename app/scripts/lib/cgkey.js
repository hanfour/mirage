// 用 CGEvent 送一次帶修飾鍵的按放，繞開 System Events 的 `keystroke`。
//
// 存在的理由（D69）：`keystroke "q" using command down` 在視窗被 `orderOut` 隱藏後
// 又 `makeKeyAndOrderFront` 顯示回來的狀態下，**應用選單的鍵等價收不到**——⌘Q 與 ⌘H
// 都不作用，而同一時刻 ⌘W（Window 選單的 Close）正常、用滑鼠點「Quit Mirage」也正常。
// 同一個 app 實例內先送 System Events 再送 CGEvent 的對照跑兩輪，兩輪都是前者無效、
// 後者一秒內退出；另有一輪只送 CGEvent 也有效，排除「前一次按鍵先喚醒了什麼」。
// 這與 cgclick.js 的存在理由同型：System Events 的合成事件在某些視窗狀態下送不到。
//
// 用法：osascript -l JavaScript cgkey.js <virtualKeyCode> <flags>
//   virtualKeyCode：Carbon 虛擬鍵碼（Q=12、W=13、H=4）
//   flags：CGEventFlags 位元遮罩（command = 1048576，即 1 << 20）
function keyArguments(argv) {
    if (argv.length !== 2) throw new Error('Expected virtualKeyCode flags');
    var values = argv.map(function (value) {
        if (!/^\d+$/.test(value)) throw new Error('Arguments must be nonnegative integers');
        var number = Number(value);
        if (!isFinite(number)) throw new Error('Arguments must be finite');
        return number;
    });
    if (values[0] > 127) throw new Error('virtualKeyCode must be 0..127');
    if (values[1] > 4294967295) throw new Error('flags must fit in 32 bits');
    return values;
}

function run(argv) {
    var args = keyArguments(argv);
    ObjC.import('CoreGraphics');
    var code = args[0], flags = args[1];
    // down 與 up 都要帶 flags：只在 down 帶，接收端會看到修飾鍵在 up 時已放開，
    // 部分應用會據此判定成不同的組合。
    var down = $.CGEventCreateKeyboardEvent($(), code, true);
    $.CGEventSetFlags(down, flags);
    $.CGEventPost(0, down);            // 0 = kCGHIDEventTap
    var up = $.CGEventCreateKeyboardEvent($(), code, false);
    $.CGEventSetFlags(up, flags);
    $.CGEventPost(0, up);
    return 'posted key ' + code + ' flags ' + flags;
}
