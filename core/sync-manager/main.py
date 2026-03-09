import os
import asyncio
import datetime
import logging
from io import BytesIO

import cocoindex
from cocoindex import flow_def, FlowBuilder, DataScope, op
from cocoindex.functions import SplitRecursively, SentenceTransformerEmbed
from cocoindex.sources import LocalFile
from cocoindex_surreal import SurrealDB
from dotenv import load_dotenv

import fitz  # PyMuPDF
import mcp_client
import conversation_sync
import contact_sync

from fastapi import FastAPI
import uvicorn
from PIL import Image, ExifTags

# Load Environment Variables
load_dotenv()

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration
SURREAL_URL = os.environ.get("SURREAL_URL", "ws://127.0.0.1:8000")
SURREAL_USER = os.environ.get("SURREAL_USER", "root")
SURREAL_PASS = os.environ.get("SURREAL_PASS", "root")
SURREAL_NS = os.environ.get("SURREAL_NS", "atomos")
SURREAL_DB = os.environ.get("SURREAL_DB", "atomos")
SURREAL_TABLE = os.environ.get("SURREAL_TABLE", "document")

HOME_DIR = os.environ.get("HOME_DIR", os.path.join(os.getcwd(), ".dev/$HOME"))
MAX_FILE_SIZE = int(os.environ.get("MAX_FILE_SIZE", 10 * 1024 * 1024)) # 10MB default
MCP_SERVERS_CONFIG_PATH = os.environ.get("MCP_SERVERS_CONFIG_PATH", os.path.join(os.getcwd(), ".dev/mcp_servers.json"))

# Fallback path for XDG_DATA_HOME logic. Typically /Users/username/.local/share/cosmic-ext-applet-ollama/chat
CONVERSATION_DIR = os.environ.get("CONVERSATION_DIR", os.path.join(os.path.expanduser("~"), ".local/share/cosmic-ext-applet-ollama/chat"))
CONTACTS_DIR = os.environ.get("CONTACTS_DIR", os.path.join(os.path.expanduser("~"), ".local/share/atomos/contacts/"))

if "COCOINDEX_DATABASE_URL" not in os.environ and not os.environ.get("TEST_MODE"):
    os.environ["COCOINDEX_DATABASE_URL"] = "postgresql://postgres:postgres@localhost:5433/cocoindex"

# Initialize CocoIndex
cocoindex.init()

# --- Custom CocoIndex Extractors ---

@op.function()
def extract_pdf_text(content: bytes) -> str:
    """Extracts text from a PDF byte array."""
    text = ""
    try:
        doc = fitz.open(stream=content, filetype="pdf")
        for page in doc:
            text += page.get_text()
    except Exception as e:
        logger.warning(f"Failed to extract PDF text: {e}")
    return text

@op.function()
def extract_image_metadata(content: bytes) -> str:
    """Extracts basic EXIF data and dimensions from an image."""
    try:
        with Image.open(BytesIO(content)) as img:
            metadata = [f"Format: {img.format}", f"Size: {img.size}", f"Mode: {img.mode}"]
            exif = img.getexif()
            if exif:
                for k, v in exif.items():
                    tag = ExifTags.TAGS.get(k, k)
                    # Keep it as basic strings for indexing
                    metadata.append(f"{tag}: {v}")
            return "\n".join(metadata)
    except Exception as e:
        logger.warning(f"Failed to extract image metadata: {e}")
        return "Image: Failed to read metadata"


@op.function()
def process_file_content(path: str, content: bytes) -> str:
    """
    Main router for processing different file types.
    Handles size checks and routes to PDF/Image specific extractors.
    """
    try:
        size = len(content)
        if size > MAX_FILE_SIZE:
             return f"Large file skipped. Size: {size} bytes. Type: metadata_only_stub."

        ext = os.path.splitext(path)[1].lower()
        if ext == ".pdf":
             return extract_pdf_text(content)
        elif ext in [".jpg", ".jpeg", ".png", ".heic"]:
             return extract_image_metadata(content)
        else:
             # Assume text
             return content.decode("utf-8", errors="ignore")
    except Exception as e:
        logger.warning(f"Error processing {path}: {e}")
        return ""


@flow_def(name="filesystem_sync_flow")
def sync_flow(flow_builder: FlowBuilder, data_scope: DataScope):
    # Source: Local Files with Live Updates
    documents = flow_builder.add_source(
        LocalFile(
            path=HOME_DIR,
            included_patterns=["**/*.md", "**/*.txt", "**/*.py", "**/*.rs", "**/*.toml", "**/*.json", "**/*.yaml", "**/*.yml", "**/*.pdf", "**/*.jpg", "**/*.png", "**/*.jpeg", "**/*.heic"],
            excluded_patterns=["**/.*", "**/target", "**/node_modules", "**/venv", "**/__pycache__"],
            # Important: Read as raw bytes to handle PDFs and Images properly
            binary=True 
        ),
        refresh_interval=datetime.timedelta(seconds=5)
    )
    
    data_scope["documents"] = documents

    with documents.row() as doc:
        # Route processing natively (decoding or custom binary extraction)
        processed_text = doc["filename"].transform(process_file_content, doc["content"])

        # Split content into chunks
        chunks = processed_text.transform(
            SplitRecursively(),
            chunk_size=500,
            chunk_overlap=50
        )
        
        # Collect each chunk
        with chunks.row() as chunk:
            embedding = chunk["text"].transform(
                SentenceTransformerEmbed(model="sentence-transformers/all-MiniLM-L6-v2")
            )
            
            collector = data_scope.add_collector()
            
            # Collect data
            collector.collect(
                path=doc["filename"],
                content=chunk["text"],
                location=chunk["location"],
                embedding=embedding
            )
            
            # Export to SurrealDB
            collector.export(
                "surreal_docs",
                SurrealDB(
                    url=SURREAL_URL,
                    user=SURREAL_USER,
                    password=SURREAL_PASS,
                    namespace=SURREAL_NS,
                    database=SURREAL_DB,
                    table_name=SURREAL_TABLE
                ),
                primary_key_fields=["path", "location"] # Composite key
            )


# --- FastAPI Health Check ---
app = FastAPI()

@app.get("/health")
async def health_check():
    return {"status": "ok", "watching": HOME_DIR}


async def run_fastapi():
    port = int(os.environ.get("PORT", 8080))
    config = uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning")
    server = uvicorn.Server(config)
    await server.serve()

async def main():
    print("Starting Filesystem Sync Service with CocoIndex...")
    print(f"Watching: {HOME_DIR}")
    
    # Start FastAPI in background
    metrics_task = asyncio.create_task(run_fastapi())
    
    # Start MCP Sync in background
    mcp_task = asyncio.create_task(
        mcp_client.mcp_polling_loop(
            config_path=MCP_SERVERS_CONFIG_PATH,
            surreal_url=SURREAL_URL,
            db_ns=SURREAL_NS,
            db_name="core" if os.environ.get("MCP_CORE_DB") else SURREAL_DB,
            doc_db_name=SURREAL_DB,
            interval_seconds=int(os.environ.get("MCP_POLL_INTERVAL", 300))
        )
    )

    # Start Conversation Sync in background
    convo_task = asyncio.create_task(
        conversation_sync.conversation_polling_loop(
            data_path=CONVERSATION_DIR,
            surreal_url=SURREAL_URL,
            db_ns=SURREAL_NS,
            db_name="core" if os.environ.get("CONVO_CORE_DB") else SURREAL_DB,
            interval_seconds=int(os.environ.get("CONVO_POLL_INTERVAL", 60))
        )
    )

    # Start Contact Sync in background
    contact_task = asyncio.create_task(
        contact_sync.contact_polling_loop(
            data_path=CONTACTS_DIR,
            surreal_url=SURREAL_URL,
            db_ns=SURREAL_NS,
            db_name="core" if os.environ.get("CONTACT_CORE_DB") else SURREAL_DB,
            interval_seconds=int(os.environ.get("CONTACT_POLL_INTERVAL", 3600))
        )
    )

    # Setup flow
    await sync_flow.setup_async(report_to_stdout=True)
    
    # Run Live Updater
    try:
        async with cocoindex.FlowLiveUpdater(
            sync_flow, 
            cocoindex.FlowLiveUpdaterOptions(print_stats=True, full_reprocess=True)
        ) as updater:
            print("Live updater started. Press Ctrl+C to stop.")
            await updater.wait_async()
            
    except KeyboardInterrupt:
        print("Stopped filesystem sync service.")
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
    
    # Cancel metrics and background tasks on exit
    metrics_task.cancel()
    mcp_task.cancel()
    convo_task.cancel()
    contact_task.cancel()

if __name__ == "__main__":
    asyncio.run(main())
