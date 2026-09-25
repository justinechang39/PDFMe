"""Generate a deterministic, non-private DOCX for integration tests and visual QA."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import sys
path = Path(sys.argv[1] if len(sys.argv) > 1 else 'work/Hello PDFMe.docx')
path.parent.mkdir(parents=True, exist_ok=True)
with ZipFile(path, 'w', ZIP_DEFLATED) as z:
    z.writestr('[Content_Types].xml', '''<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>''')
    z.writestr('_rels/.rels', '''<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>''')
    z.writestr('word/document.xml', '''<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
<w:p><w:r><w:rPr><w:color w:val="416347"/><w:b/><w:sz w:val="22"/></w:rPr><w:t>PDFMe / CONVERSION CHECK</w:t></w:r></w:p>
<w:p><w:r><w:rPr><w:sz w:val="60"/><w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica"/></w:rPr><w:t>PDF conversion test</w:t></w:r></w:p>
<w:p><w:r><w:t>This document checks text, formatting, tables, Unicode, and page breaks.</w:t></w:r></w:p>
<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Bold stays bold. </w:t></w:r><w:r><w:rPr><w:i/></w:rPr><w:t>Italic stays italic.</w:t></w:r></w:p>
<w:p><w:r><w:t>Unicode: café · résumé · こんにちは</w:t></w:r></w:p>
<w:tbl><w:tblPr><w:tblW w:w="9000" w:type="dxa"/><w:tblBorders><w:top w:val="single" w:sz="4"/><w:bottom w:val="single" w:sz="4"/><w:insideH w:val="single" w:sz="4"/></w:tblBorders></w:tblPr><w:tblGrid><w:gridCol w:w="4500"/><w:gridCol w:w="4500"/></w:tblGrid>
<w:tr><w:tc><w:tcPr><w:tcW w:w="4500" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>Feature</w:t></w:r></w:p></w:tc><w:tc><w:tcPr><w:tcW w:w="4500" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>Expected result</w:t></w:r></w:p></w:tc></w:tr>
<w:tr><w:tc><w:p><w:r><w:t>Selectable text</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Preserved</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
<w:p><w:r><w:rPr><w:sz w:val="40"/><w:b/></w:rPr><w:t>Page two, too.</w:t></w:r></w:p>
<w:p><w:r><w:t>Explicit page breaks should survive conversion.</w:t></w:r></w:p>
<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>
</w:body></w:document>''')
print(path)
