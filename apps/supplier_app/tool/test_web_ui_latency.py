import io
import unittest
import xml.etree.ElementTree as ET
import zipfile

from web_ui_latency import large_workbook, summarize


class LatencyEvidenceTest(unittest.TestCase):
    def test_missing_invalid_samples_cannot_pass(self):
        for samples in [[], [1] * 19, [1] * 21, [float('nan')] * 20, [-1] * 20]:
            with self.assertRaises(ValueError):
                summarize(samples, 1000)

    def test_tail_breach_fails_even_when_p95_passes(self):
        result = summarize([30] * 19 + [1001], 1000)
        self.assertEqual(result['p95_ms'], 30)
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(summarize([1000] * 20, 1000)['status'], 'PASS')

    def test_fixture_keeps_unique_row_and_cell_coordinates(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as archive:
            archive.writestr('xl/worksheets/sheet1.xml', '<worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>header</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>value</t></is></c></row></sheetData></worksheet>')
        with zipfile.ZipFile(io.BytesIO(large_workbook(data.getvalue(), 100))) as archive:
            root = ET.fromstring(archive.read('xl/worksheets/sheet1.xml'))
        rows = root.findall('./sheetData/row')
        self.assertEqual(len(rows), 101)
        self.assertEqual([r.attrib['r'] for r in rows], [str(i) for i in range(1, 102)])
        self.assertEqual([r.find('c').attrib['r'] for r in rows], [f'A{i}' for i in range(1, 102)])


if __name__ == '__main__':
    unittest.main()
