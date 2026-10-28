import os, sys, tempfile, unittest
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
from lib import snap  # noqa: E402


class SnapKey(unittest.TestCase):
    def test_comma_list_first_key(self):
        os.environ["LLAMA_API_KEY"] = "k1,k2"
        try:
            self.assertEqual(snap.local_api_key(), "k1")
        finally:
            del os.environ["LLAMA_API_KEY"]

    def test_file_fallback(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("# c\nfilekey\n")
        os.environ["API_KEY_FILE"] = f.name
        try:
            self.assertEqual(snap.local_api_key(), "filekey")
        finally:
            del os.environ["API_KEY_FILE"]; os.unlink(f.name)


if __name__ == "__main__":
    unittest.main()
