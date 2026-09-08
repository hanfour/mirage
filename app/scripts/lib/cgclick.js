function clickArguments(argv) {
    if (argv.length !== 4) throw new Error('Expected x y count gapSeconds');
    var values = argv.map(function (value) {
        if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(value)) {
            throw new Error('Arguments must be numeric');
        }
        var number = Number(value);
        if (!isFinite(number)) throw new Error('Arguments must be finite');
        return number;
    });
    if (values[2] <= 0 || Math.floor(values[2]) !== values[2] || values[2] > 9007199254740991) {
        throw new Error('Count must be a positive safe integer');
    }
    if (values[3] < 0) throw new Error('Gap must be nonnegative');
    return values;
}

function run(argv) {
    var args = clickArguments(argv);
    ObjC.import('CoreGraphics');
    ObjC.import('Foundation');
    var x = args[0], y = args[1], n = args[2], gap = args[3];
    var pt = $.CGPointMake(x, y);
    for (var i = 0; i < n; i++) {
        var down = $.CGEventCreateMouseEvent($(), 1, pt, 0);
        $.CGEventPost(0, down);
        delay(0.03);
        var up = $.CGEventCreateMouseEvent($(), 2, pt, 0);
        $.CGEventPost(0, up);
        delay(gap);
    }
    return 'posted ' + n + ' clicks at ' + x + ',' + y;
}
