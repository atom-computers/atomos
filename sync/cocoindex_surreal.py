
import asyncio
import logging
import dataclasses
import hashlib
from typing import Any, Dict, List, Union, Optional
from surrealdb import AsyncSurreal
from cocoindex import op
from cocoindex.engine_type import FieldSchema
import datetime
import os

_logger = logging.getLogger(__name__)

class SurrealDB(op.TargetSpec):
    url: str
    user: str
    password: str
    namespace: str
    database: str
    table_name: str

@dataclasses.dataclass
class _State:
    key_fields_schema: List[FieldSchema]
    value_fields_schema: List[FieldSchema]

@dataclasses.dataclass
class _TableKey:
    url: str
    namespace: str
    database: str
    table_name: str

@dataclasses.dataclass
class _MutateContext:
    db: AsyncSurreal
    table_name: str
    key_field_names: List[str]

@op.target_connector(
    spec_cls=SurrealDB, persistent_key_type=_TableKey, setup_state_cls=_State
)
class _Connector:
    @staticmethod
    def get_persistent_key(spec: SurrealDB) -> _TableKey:
        print(f"DEBUG: get_persistent_key called for table {spec.table_name}")
        return _TableKey(
            url=spec.url,
            namespace=spec.namespace,
            database=spec.database,
            table_name=spec.table_name,
        )

    @staticmethod
    def get_setup_state(
        spec: SurrealDB,
        key_fields_schema: List[FieldSchema],
        value_fields_schema: List[FieldSchema],
        index_options: Any,
    ) -> _State:
        print(f"DEBUG: get_setup_state called")
        return _State(
            key_fields_schema=key_fields_schema,
            value_fields_schema=value_fields_schema,
        )

    @staticmethod
    def describe(key: _TableKey) -> str:
        return f"SurrealDB table {key.table_name} @ {key.url}"

    @staticmethod
    def check_state_compatibility(
        previous: _State, current: _State
    ) -> op.TargetStateCompatibility:
        print(f"DEBUG: check_state_compatibility called")
        return op.TargetStateCompatibility.COMPATIBLE

    @staticmethod
    async def apply_setup_change(
        key: _TableKey, previous: _State | None, current: _State | None
    ) -> None:
        pass

    @staticmethod
    async def prepare(
        spec: SurrealDB,
        setup_state: _State,
    ) -> _MutateContext:
        print(f"DEBUG: prepare called for {spec.url}")
        db = AsyncSurreal(spec.url)
        await db.connect() 
        # await db.signin({"user": spec.user, "pass": spec.password})
        await db.use(spec.namespace, spec.database)
        
        return _MutateContext(
            db=db,
            table_name=spec.table_name,
            key_field_names=[f.name for f in setup_state.key_fields_schema],
        )

    @staticmethod
    async def mutate(
        *all_mutations: tuple[_MutateContext, dict[Any, dict[str, Any] | None]],
    ) -> None:
        print(f"DEBUG: mutate called with {len(all_mutations)} batches")
        for context, mutations in all_mutations:
            print(f"DEBUG: Processing batch for table {context.table_name} with {len(mutations)} mutations")
            try:
                for key_val, value_fields in mutations.items():
                    # Key handling: could be single value or tuple of values
                    
                    # Generate deterministic ID
                    if isinstance(key_val, tuple):
                        # Composite key
                        raw_key = "_".join(str(k) for k in key_val)
                    else:
                        raw_key = str(key_val)
                        
                    hashed_id = hashlib.sha256(raw_key.encode()).hexdigest()
                    record_id = f"{context.table_name}:{hashed_id}"
                    
                    if value_fields is None:
                        # Delete
                        await context.db.delete(record_id)
                    else:
                        # Upsert
                        processed_value = {}
                        
                        if isinstance(key_val, tuple):
                            for k_name, k_v in zip(context.key_field_names, key_val):
                                processed_value[k_name] = k_v
                        else:
                             processed_value[context.key_field_names[0]] = key_val

                        # Calculate modified_at if "path" is in processed_value
                        if "path" in processed_value:
                            try:
                                ts = os.path.getmtime(processed_value["path"])
                                processed_value["modified_at"] = datetime.datetime.fromtimestamp(ts)
                            except:
                                processed_value["modified_at"] = datetime.datetime.now()

                        for k, v in value_fields.items():
                            if hasattr(v, "tolist"):
                                processed_value[k] = v.tolist()
                            else:
                                processed_value[k] = v
                                
                        # Try to create first (if not exists)
                        try:
                            # print(f"DEBUG: Creating {record_id}")
                            await context.db.create(record_id, processed_value)
                        except Exception as create_error:
                            # print(f"DEBUG: Create failed ({create_error}), retrying with update")
                            # If create fails (likely exists), try update
                            await context.db.update(record_id, processed_value)
                        
            except Exception as e:
                _logger.error(f"Error mutating SurrealDB: {e}")
                print(f"DEBUG: Error mutating SurrealDB: {e}")
                import traceback
                traceback.print_exc()
