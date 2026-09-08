// cgkey.js 的自我測試：不送出任何真實事件，把 CoreGraphics 換成 mock。
// 用法：osascript -l JavaScript cgkey_selftest.js <cgkey.js 的路徑>
ObjC.import('Foundation');
function run(argv) {
    var source = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null));
    var events = [], flagsSet = [], imports = [];
    var mock = function () { return null; };
    mock.CGEventCreateKeyboardEvent = function (source, code, isDown) {
        return { code: code, down: isDown, flags: null };
    };
    mock.CGEventSetFlags = function (event, flags) {
        event.flags = flags;
        flagsSet.push(flags);
    };
    mock.CGEventPost = function (tap, event) { events.push([tap, event]); };
    var key = Function('ObjC', '$', source + '\nreturn run;')(
        { import: function (name) { imports.push(name); } }, mock);
    function check(ok) { if (!ok) throw new Error('cgkey assertion failed'); }

    var invalid = [[], ['12'], ['12', '0', '0'],
        ['abc', '0'], ['12', 'abc'], ['', '0'], ['12', ''],
        ['-1', '0'], ['12', '-1'], ['1.5', '0'], ['12', '1.5'],
        ['128', '0'], ['12', '4294967296']];
    invalid.forEach(function (args) {
        var rejected = false;
        try { key(args); } catch (error) { rejected = true; }
        check(rejected);
    });
    // 任何一次拒絕都不可以已經送出事件或 import 過 CoreGraphics。
    check(imports.length === 0 && events.length === 0 && flagsSet.length === 0);

    check(key(['12', '1048576']) === 'posted key 12 flags 1048576');
    check(imports.length === 1 && imports[0] === 'CoreGraphics');
    // 一次按放剛好兩個事件，且 down 在 up 之前。
    check(events.length === 2);
    check(events[0][0] === 0 && events[1][0] === 0);
    check(events[0][1].code === 12 && events[1][1].code === 12);
    check(events[0][1].down === true && events[1][1].down === false);
    // down 與 up 都必須帶上修飾鍵，這正是 cgkey.js 註解裡說明的那條。
    check(flagsSet.length === 2 && flagsSet[0] === 1048576 && flagsSet[1] === 1048576);
    check(events[0][1].flags === 1048576 && events[1][1].flags === 1048576);

    // 邊界值可用：keyCode 0 與 127、flags 0 與 32 位元上限。
    check(key(['0', '0']) === 'posted key 0 flags 0');
    check(key(['127', '4294967295']) === 'posted key 127 flags 4294967295');
    check(events.length === 6);
    return 'cgkey selftest ok';
}
