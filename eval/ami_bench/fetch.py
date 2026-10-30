"""Downloads the AMI Meeting Corpus' manual annotations (23 MB, CC BY 4.0, University of Edinburgh)
into eval/ami_bench/data/ami, then converts the benchmark's meetings into MeetScribe sessions.

  python3 eval/ami_bench/fetch.py
"""
import io
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
URL = "https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip"
KEEP = ("abstractive/", "words/", "corpusResources/", "LICENCE.txt")  # the rest isn't used

corpus = HERE / "data" / "ami"
if not (corpus / "abstractive").exists():
    print(f"downloading {URL}", flush=True)
    with urllib.request.urlopen(URL) as r:
        z = zipfile.ZipFile(io.BytesIO(r.read()))
    z.extractall(corpus, [n for n in z.namelist() if n.startswith(KEEP)])
subprocess.run([sys.executable, str(HERE / "convert.py")], check=True)
