# Configuration file for the Sphinx documentation builder.

import datetime
from pathlib import Path
import subprocess

project = "pmaports"
copyright = str(datetime.date.today().year) + ", postmarketOS contributors"
exclude_patterns = ["_build", "_out", "Thumbs.db", ".DS_Store", ".venv", "README.md"]

extensions = [
    "myst_parser",
    "sphinx.ext.autodoc",
    "sphinx.ext.autosummary",
    "sphinx.ext.doctest",
    "sphinxcontrib.autoprogram",
    "sphinxcontrib.jquery",
]
myst_enable_extensions = ["colon_fence"]

html_theme = "pmos"
html_theme_options = {
    "source_edit_link": "https://gitlab.postmarketos.org/postmarketOS/pmaports/-/blob/main/docs/{filename}",
}

# Set the explicit title of the HTML output
html_title = "postmarketOS Packaging"


def run_dint_doc(app):
    docs_dir = Path(__file__).parent

    with docs_dir.joinpath("deviceinfo-reference.md").open("w") as f:
        schema_path = docs_dir.parent / "deviceinfo_schema.toml"

        subprocess.run(["dint", "doc"], stdout=f, check=True, env={"DINT_SCHEMA_PATH": schema_path})


def setup(app):
    app.connect("builder-inited", run_dint_doc)
