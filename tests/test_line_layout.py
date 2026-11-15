import unittest

from FileBrowser.common import (
    BIT_OFF, BIT_ON, COLUMN_SEP, FLAG_EXCLUDED, FLAG_HIDDEN, FLAG_LINK, FLAG_SYSTEM,
    FLAG_WIDTH, SEGMENT_SEP, decode_flags, encode_flags, name_field, split_line,
    visible_len)

SEG = SEGMENT_SEP
COL = COLUMN_SEP


def item_line(flags=0, depth=0, icon='≡ ', name='file.txt', note='', stats=()):
    pad = '\t' if note else ''
    line = '\t' * depth + SEG + encode_flags(flags) + SEG + icon + SEG + name + pad + SEG + note
    for column in stats:
        line += '  ' + COL + column
    return line


class FlagsTest(unittest.TestCase):
    def test_round_trip(self):
        for flags in (0, FLAG_HIDDEN, FLAG_SYSTEM | FLAG_LINK, FLAG_HIDDEN | FLAG_EXCLUDED):
            encoded = encode_flags(flags)
            self.assertEqual(len(encoded), FLAG_WIDTH)
            self.assertEqual(decode_flags(encoded), flags)

    def test_bit_order(self):
        self.assertEqual(encode_flags(FLAG_HIDDEN)[:2], BIT_ON + BIT_OFF)
        self.assertEqual(encode_flags(FLAG_SYSTEM)[:2], BIT_OFF + BIT_ON)

    def test_unset_bits_are_written(self):
        self.assertEqual(encode_flags(0), BIT_OFF * FLAG_WIDTH)


class SplitLineTest(unittest.TestCase):
    def test_file_without_stats(self):
        fields, stats = split_line(item_line(FLAG_HIDDEN, depth=2))
        self.assertEqual(fields[0], '\t\t')
        self.assertEqual(decode_flags(fields[1]), FLAG_HIDDEN)
        self.assertEqual(fields[2].strip(), '≡')
        self.assertEqual(name_field(fields), 'file.txt')
        self.assertEqual(fields[4], '')
        self.assertEqual(stats, [])

    def test_directory_with_note_and_stats(self):
        line = item_line(icon='▸ ', name='dir/', note='<empty>',
                         stats=('DIR', '13.11.2025 00:04', 'H-'))
        fields, stats = split_line(line)
        self.assertEqual(name_field(fields), 'dir/')
        self.assertEqual(fields[4].strip(), '<empty>')
        self.assertEqual([s.strip() for s in stats], ['DIR', '13.11.2025 00:04', 'H-'])

    def test_empty_stats_fields_keep_their_position(self):
        _, stats = split_line(item_line(stats=('12', '', '--')))
        self.assertEqual([s.strip() for s in stats], ['12', '', '--'])

    def test_non_item_lines(self):
        self.assertIsNone(split_line('⠤'))
        self.assertIsNone(split_line('~/projects → header'))

    def test_separator_in_name_breaks_the_structure(self):
        self.assertIsNone(split_line(item_line(name='bad' + SEG + 'name')))
        self.assertIsNone(split_line(item_line(name='bad' + COL + 'name')))


class VisibleLenTest(unittest.TestCase):
    def test_structure_characters_have_no_width(self):
        self.assertEqual(visible_len(item_line(name='abc'), 4), len('≡ abc'))

    def test_tab_stops_ignore_structure_characters(self):
        line = item_line(depth=1, icon='▸ ', name='d/', note='<x>')
        # '\t' -> 4, '▸ d/' -> 8, '\t' to the next stop -> 12, '<x>' -> 15
        self.assertEqual(visible_len(line, 4), 15)
