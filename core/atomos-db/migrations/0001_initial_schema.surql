-- Migration: 0001_initial_schema.surql

-- Name: initial_schema
-- Created: 2026-02-22

-- 1. MCP Registry
DEFINE TABLE mcp_server SCHEMALESS;
DEFINE FIELD name ON mcp_server TYPE string;
DEFINE FIELD url ON mcp_server TYPE string;
DEFINE FIELD status ON mcp_server TYPE string DEFAULT "disconnected";
DEFINE FIELD supported_tools ON mcp_server TYPE option<array<string>>;
DEFINE FIELD last_connected ON mcp_server TYPE option<datetime>;

-- 2. Conversation History
DEFINE TABLE chat_thread SCHEMALESS;
DEFINE FIELD title ON chat_thread TYPE string;
DEFINE FIELD created_at ON chat_thread TYPE datetime DEFAULT time::now();
DEFINE FIELD updated_at ON chat_thread TYPE datetime DEFAULT time::now();
DEFINE FIELD context_id ON chat_thread TYPE option<record<project_context>>;

DEFINE TABLE chat_message SCHEMALESS;
DEFINE FIELD thread_id ON chat_message TYPE record<chat_thread>;
DEFINE FIELD role ON chat_message TYPE string ASSERT $value IN ["user", "assistant", "system"];
DEFINE FIELD content ON chat_message TYPE string;
DEFINE FIELD meta ON chat_message TYPE option<object>;
DEFINE FIELD timestamp ON chat_message TYPE datetime DEFAULT time::now();

-- 3. Contacts
DEFINE TABLE contact SCHEMALESS;
DEFINE FIELD name ON contact TYPE string;
DEFINE FIELD aliases ON contact TYPE option<array<string>>;
DEFINE FIELD metadata ON contact TYPE option<object>;
DEFINE FIELD relations ON contact TYPE option<array<record>>;

-- 4. Context Store
DEFINE TABLE project_context SCHEMALESS;
DEFINE FIELD name ON project_context TYPE string;
DEFINE FIELD path ON project_context TYPE string;
DEFINE FIELD status ON project_context TYPE string DEFAULT "active" ASSERT $value IN ["active", "archived"];
DEFINE FIELD created_at ON project_context TYPE datetime DEFAULT time::now();
DEFINE FIELD last_active ON project_context TYPE datetime DEFAULT time::now();
DEFINE FIELD summary ON project_context TYPE option<string>;
DEFINE FIELD classification ON project_context TYPE option<string> ASSERT $value == NONE OR $value IN ["work", "personal"];

-- 5. Task/Workflow Persistence
DEFINE TABLE workflow_execution SCHEMALESS;
DEFINE FIELD name ON workflow_execution TYPE string;
DEFINE FIELD status ON workflow_execution TYPE string DEFAULT "pending" ASSERT $value IN ["pending", "running", "completed", "failed", "cancelled"];
DEFINE FIELD created_at ON workflow_execution TYPE datetime DEFAULT time::now();
DEFINE FIELD updated_at ON workflow_execution TYPE datetime DEFAULT time::now();
DEFINE FIELD state_data ON workflow_execution TYPE option<object>;

DEFINE TABLE workflow_event SCHEMALESS;
DEFINE FIELD execution_id ON workflow_event TYPE record<workflow_execution>;
DEFINE FIELD event_type ON workflow_event TYPE string;
DEFINE FIELD payload ON workflow_event TYPE option<object>;
DEFINE FIELD timestamp ON workflow_event TYPE datetime DEFAULT time::now();

-- 6. Security Certificates & Whitelisting
DEFINE TABLE security_certificate SCHEMALESS;
DEFINE FIELD service_name ON security_certificate TYPE string;
DEFINE FIELD public_key ON security_certificate TYPE string;
DEFINE FIELD issued_at ON security_certificate TYPE datetime DEFAULT time::now();
DEFINE FIELD expires_at ON security_certificate TYPE datetime;
DEFINE FIELD status ON security_certificate TYPE string DEFAULT "active" ASSERT $value IN ["active", "revoked", "expired"];

DEFINE TABLE security_whitelist SCHEMALESS;
DEFINE FIELD entity ON security_whitelist TYPE string;
DEFINE FIELD permission ON security_whitelist TYPE string;
DEFINE FIELD approved_at ON security_whitelist TYPE datetime DEFAULT time::now();
DEFINE FIELD approved_by ON security_whitelist TYPE string;
