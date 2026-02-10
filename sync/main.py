
import os
import asyncio
import cocoindex
from cocoindex import flow_def, FlowBuilder, DataScope
from cocoindex.functions import SplitRecursively, SentenceTransformerEmbed
from cocoindex.sources import LocalFile
from cocoindex_surreal import SurrealDB
import datetime
import logging

# Configure logging
logging.basicConfig(level=logging.INFO)

# Configuration
SURREAL_URL = "ws://127.0.0.1:8000"
SURREAL_USER = "root"
SURREAL_PASS = "root"
SURREAL_NS = "atomos"
SURREAL_DB = "filesystem"
SURREAL_TABLE = "document"

HOME_DIR = os.path.join(os.getcwd(), '.dev/$HOME') # Use current dir for faster testing loop instead of home

# Configure CocoIndex Database (Postgres)
# Using the docker container we spun up: postgres:postgres@localhost:5432/cocoindex
if "COCOINDEX_DATABASE_URL" not in os.environ:
    os.environ["COCOINDEX_DATABASE_URL"] = "postgresql://postgres:postgres@localhost:5433/cocoindex"

# Initialize CocoIndex
cocoindex.init()

@flow_def(name="filesystem_sync_flow")
def sync_flow(flow_builder: FlowBuilder, data_scope: DataScope):
    # Source: Local Files with Live Updates
    # Refresh every 5 seconds
    documents = flow_builder.add_source(
        LocalFile(
            path=HOME_DIR,
            included_patterns=["**/*.md", "**/*.txt", "**/*.py", "**/*.rs", "**/*.toml", "**/*.json", "**/*.yaml", "**/*.yml"],
            excluded_patterns=["**/.*", "**/target", "**/node_modules", "**/venv", "**/__pycache__"]
        ),
        refresh_interval=datetime.timedelta(seconds=5)
    )
    
    # Store source documents in data_scope for collection
    data_scope["documents"] = documents

    # Process each document
    with documents.row() as doc:
        # Split content into chunks
        chunks = doc["content"].transform(
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

async def main():
    print("Starting Filesystem Sync Service with CocoIndex...")
    print(f"Watching: {HOME_DIR}")
    
    # Setup flow (generates code/structures)
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

if __name__ == "__main__":
    asyncio.run(main())
