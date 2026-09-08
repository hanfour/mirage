ObjC.import('Foundation');
function run(argv) {
    var source = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null));
    var events = [], waits = [], imports = [];
    var mock = function () { return null; };
    mock.CGPointMake = function (x, y) { return [x, y]; };
    mock.CGEventCreateMouseEvent = function (source, type, point, button) {
        return { type: type, point: point, button: button };
    };
    mock.CGEventPost = function (tap, event) { events.push([tap, event]); };
    var click = Function('ObjC', '$', 'delay', source + '\nreturn run;')(
        { import: function (name) { imports.push(name); } }, mock,
        function (seconds) { waits.push(seconds); });
    function check(ok) { if (!ok) throw new Error('cgclick assertion failed'); }
    var invalid = [[], ['1'], ['1','2','3'], ['1','2','3','0','5'],
        ['abc','2','3','0'], ['1x','2','3','0'], ['', '2','3','0'],
        ['1','NaN','3','0'], ['Infinity','2','3','0'], ['1e999','2','3','0'],
        ['1','2','0','0'], ['1','2','-1','0'], ['1','2','1.5','0'],
        ['1','2','9007199254740992','0'], ['1','2','3','-0.1'], ['1','2','3','oops']];
    invalid.forEach(function (args) {
        var rejected = false;
        try { click(args); } catch (error) { rejected = true; }
        check(rejected);
    });
    check(imports.length === 0 && events.length === 0 && waits.length === 0);
    check(click(['644.5','336.0','8','0.5']) === 'posted 8 clicks at 644.5,336');
    check(events.length === 16 && waits.length === 16);
    events.forEach(function (entry, i) {
        check(entry[0] === 0 && entry[1].type === (i % 2 ? 2 : 1));
        check(entry[1].button === 0 && entry[1].point[0] === 644.5 && entry[1].point[1] === 336);
        check(waits[i] === (i % 2 ? 0.5 : 0.03));
    });
    check(click(['-10','.5','1','0']) === 'posted 1 clicks at -10,0.5');
    return 'cgclick selftest passed (mock CGEvent, no GUI events)';
}
