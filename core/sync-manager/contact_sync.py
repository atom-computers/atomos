import asyncio
import logging
import os
import subprocess
from typing import Dict, Any, List
import hashlib

import vobject
from surrealdb import AsyncSurreal

logger = logging.getLogger(__name__)

def parse_vcf_file(filepath: str) -> List[Dict[str, Any]]:
    """
    Parses a VCard (.vcf) file using `vobject` and extracts contact dictionaries.
    Returns a list of dictionaries mapping to the Contact schema.
    """
    contacts = []
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
            
        for vcard in vobject.readComponents(content):
            name = ""
            if hasattr(vcard, 'fn'):
                name = vcard.fn.value
            elif hasattr(vcard, 'n'):
                name = f"{vcard.n.value.given} {vcard.n.value.family}".strip()
            
            if not name:
                continue # Skip contacts without names

            uid = ""
            if hasattr(vcard, 'uid'):
                uid = vcard.uid.value
            else:
                uid = hashlib.sha256(name.encode('utf-8')).hexdigest()

            metadata = {}
            aliases = []
            
            if hasattr(vcard, 'email'):
                metadata['emails'] = [email.value for email in vcard.contents.get('email', [])]
            if hasattr(vcard, 'tel'):
                metadata['phones'] = [tel.value for tel in vcard.contents.get('tel', [])]
            if hasattr(vcard, 'title'):
                metadata['title'] = vcard.title.value
            if hasattr(vcard, 'org'):
                metadata['org'] = [org for org in vcard.org.value]
                
            if hasattr(vcard, 'nickname'):
                aliases = [nick.value for nick in vcard.contents.get('nickname', [])]

            contacts.append({
                "uid": uid,
                "name": name,
                "aliases": aliases,
                "metadata": metadata,
            })
            
    except Exception as e:
        logger.error(f"Failed to parse VCF file {filepath}: {e}")
        
    return contacts

async def sync_contacts(data_path: str, db: AsyncSurreal, table_name: str = "contact"):
    """
    Reads all .vcf files in the data_path, parses them, and upserts them
    into the database preserving the UID to prevent duplicates.
    """
    if not os.path.exists(data_path):
        try:
            os.makedirs(data_path, exist_ok=True)
            logger.info(f"Created contact data path at {data_path}")
        except Exception as e:
            logger.warning(f"Contact path not found at {data_path} and could not create it. Skipping sync: {e}")
            return

    # Attempt to dump GNOME Contacts from Evolution Data Server via syncevolution
    try:
        gnome_vcf_path = os.path.join(data_path, "gnome_contacts.vcf")
        logger.info("Attempting to export GNOME Contacts via syncevolution...")
        # Redirect stderr to stdout to capture any diagnostic output if it fails
        result = subprocess.run(
            [
                "syncevolution",
                "--export",
                gnome_vcf_path,
                "backend=evolution-contacts",
                "database=system-address-book"
            ],
            capture_output=True,
            text=True,
            check=False # We handle the error manually
        )
        if result.returncode != 0:
             logger.warning(f"Failed to export GNOME Contacts (syncevolution might not be configured yet or is missing). Output: {result.stdout.strip()} {result.stderr.strip()}")
        else:
             logger.info(f"Successfully exported GNOME Contacts to {gnome_vcf_path}")
    except Exception as e:
         logger.warning(f"Error executing syncevolution to export GNOME contacts: {e}")

    logger.info(f"Scanning for contact files in {data_path}")
    
    try:
        files = [f for f in os.listdir(data_path) if f.lower().endswith('.vcf')]
        total_synced = 0
        
        for file in files:
            filepath = os.path.join(data_path, file)
            contacts = parse_vcf_file(filepath)
            
            for contact in contacts:
                # Upsert Contact
                # Using the UID as the predictable Record ID
                safe_uid = "".join(c for c in contact["uid"] if c.isalnum() or c in "-_")
                record_id = f"{table_name}:⟨{safe_uid}⟩"
                
                record_data = {
                    "name": contact["name"],
                    "aliases": contact["aliases"],
                    "metadata": contact["metadata"],
                    "relations": [] # To be populated by contact association logic later
                }
                
                try:
                    await db.update(record_id, record_data)
                except Exception:
                    try:
                        await db.create(record_id, record_data)
                    except Exception as e:
                        logger.error(f"Failed to upsert contact {record_id}: {e}")
                        continue
                
                total_synced += 1

        logger.info(f"Successfully synced {total_synced} contacts from {len(files)} VCF files.")
    except Exception as e:
        logger.error(f"Failed during contact sync: {e}")

async def contact_polling_loop(data_path: str, surreal_url: str, db_ns: str, db_name: str, interval_seconds: int = 3600):
    """
    Background block to repeatedly poll and ingest VCF contacts.
    Defaults to 1 hour polling since contacts don't change by the second usually.
    """
    # Create DB connection
    db = AsyncSurreal(surreal_url)
    try:
        await db.connect()
        await db.use(db_ns, db_name)
    except Exception as e:
        logger.error(f"SurrealDB connection failed during Contact sync: {e}")
        return

    while True:
        logger.info("Running scheduled Contact sync...")
        await sync_contacts(data_path, db)
        await asyncio.sleep(interval_seconds)
