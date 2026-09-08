import collections

import numpy as np
import pytest

from e2e_latency import (Sample, arguments, difference_pixels, region, scan, sensitivity,
                         summarize, latency_row, matched_sensitivity)


def test_ack_filter_and_negative_samples():
    baseline = np.zeros((2, 2, 3), dtype=np.int16)
    hits = {}
    scan([Sample(1, 12, 10.5, baseline+50), Sample(2, 13, 12, baseline+50)],
         0, baseline, 11, (1,), hits)
    assert hits[1].seq == 2
    assert latency_row(10, 11, Sample(1, 12, 10.5, baseline)) is None
    assert latency_row(10, 11, Sample(2, 11, 12, baseline)) is None
    assert latency_row(10, 11, hits[1]) == (1000, 1000, 1000, 3000)


def test_sensitivity_matches_touch_ids(capsys):
    def row(total):
        return (1, 2, 3, total)
    results = {1: {0: row(100), 1: row(200), 2: row(200)},
               4: {0: row(150), 1: row(200)}, 16: {0: row(200)}}
    assert '不可引用' in matched_sensitivity(results, (1, 4, 16))
    assert '三門檻皆命中的樣本數=1' in capsys.readouterr().out
    results[4] = {}
    assert '不可引用' in matched_sensitivity(results, (1, 4, 16))


def test_pixels_not_region_average_and_no_unsigned_wrap():
    baseline = np.full((2, 2, 3), 200, dtype=np.int16)
    current = baseline.copy()
    current[0, 0, 1] = 169
    current[0, 1, :] = 170
    assert difference_pixels(current, baseline) == 1


def test_top_down_crop():
    pixels = np.zeros((4, 4, 4), dtype=np.uint8)
    pixels[:2, :2, :3] = 123
    assert np.all(region(pixels.tobytes(), 4, 4, 1, 1, 1) == 123)


def test_sequence_cursor_survives_full_deque_and_thresholds_share_frames():
    baseline = np.zeros((2, 2, 3), dtype=np.int16)
    frames = collections.deque(maxlen=2)
    hits = {}
    cursor = 0
    for seq in range(1, 8):
        current = baseline.copy()
        if seq >= 6:
            current[0, 0, 0] = 31
        if seq == 7:
            current[:, :, 0] = 31
        frames.append(Sample(seq, 10+seq, 9+seq, current))
        cursor = scan(list(frames), cursor, baseline, 10, (1, 4), hits)
    assert cursor == 7
    assert hits[1].seq == 6
    assert hits[4].seq == 7


def test_old_generated_frame_is_not_a_response():
    baseline = np.zeros((2, 2, 3), dtype=np.int16)
    hits = {}
    assert scan([Sample(5, 20, 9, baseline+50)], 4, baseline, 10, (1,), hits) == 5
    assert hits == {}


def test_misses_and_four_segments_are_explicit(capsys):
    summarize('threshold=200', [(2, 90, 12, 104)], 40)
    output = capsys.readouterr().out
    assert 'misses=39; statistics exclude misses' in output
    for segment in ('send_to_ack', 'ack_to_generated', 'transit', 'total'):
        assert segment in output
    summarize('empty', [], 40)
    assert 'p50=NA p95=NA' in capsys.readouterr().out


def test_sensitivity_warning():
    assert '不可引用' in sensitivity([100], [121])
    assert '不可引用' in sensitivity([], [121])
    assert '<=20%' in sensitivity([100], [120])


@pytest.mark.parametrize('argv', [['--samples', '0'], ['--threshold', 'nan'], ['--x', '-1']])
def test_bad_arguments(argv):
    with pytest.raises(SystemExit):
        arguments(argv)
