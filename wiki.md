Service Bus BCP Sync Strategy — ADO Task 75802
Author: Satwika Aluri
Date: 2026-06-20
Reviewers: Prashant Chawla, Tim, Deb

**Overview
This document covers the investigation, findings, strategy and implementation for syncing data between the Primary (PRD) and BCP Service Bus namespaces as part of the Business Continuity Plan (BCP) for the US SDT Tax platform.
**
Current State — Investigation Findings
Namespaces Identified
Namespace	Environment	Region	SKU	Zone Redundant
azuse2shdprdsbns01	PRD	East US 2	Premium	Yes
azuse2shdprdsbns02	PRD	East US 2	Premium	Yes
azuscshdbcpsbns01	BCP	Central US	Premium	Yes
azuscshdbcpsbns02	BCP	Central US	Premium	Yes

Key Findings

All namespaces are Premium tier and Zone Redundant — prerequisites for Geo-Replication are met
GeoDataReplication is null on both PRD and BCP namespaces — starting completely fresh
PRD namespace (azuse2shdprdsbns01) has public network access completely disabled — routes strictly via private endpoint (azuse2shdprdsbns01-pep)
BCP namespace (azuscshdbcpsbns01) had a private endpoint already pre-existing (azuscshdbcpsbns01-pep) — confirmed provisioningState: Succeeded, status: Approved
BCP and PRD namespaces are currently completely disconnected — no replication configured
Network Details
Resource	PRD	BCP
VNet	AZ-EUS2-TAX-PRD-SDT-VNET-01	AZ-CUS-TAX-BCP-SDT-VNET-01
Subnet	sdtPRD-subnet	sdtBCP-subnet
VNet RG	AZRG-ALL-ITS-VNET-SYS	AZRG-ALL-ITS-VNET-SYS
Private Endpoint	azuse2shdprdsbns01-pep 	azuscshdbcpsbns01-pep 
DNS Zone	privatelink.servicebus.windows.net	Not created yet 
Options Considered

Option 1 — Geo-DR Alias (Metadata Only)
Native Azure feature
Replicates only entity metadata (queues, topics, subscriptions)
Does NOT replicate in-flight messages
Prashant flagged this as insufficient

Option 2 — Standard to Premium Upgrade
Not applicable — all namespaces are already Premium
Upgrade is actually a namespace recreation — too risky for PRD

Option 3 — Geo-Replication (Metadata + Messages) 
Newer Azure Premium feature (GeoDataReplication)
Replicates both entity configuration AND messages across regions
Requires private endpoints on both sides
Requires privatelink.servicebus.windows.net DNS zone linked to BCP VNet
Prashant confirmed this is the required approach

Option 4 — Custom Config Sync Pipeline  Implemented
Follows existing org pattern (KV sync by Serhii Vakulenko)
GitHub Actions workflow — plan/apply with approval gate
Syncs queues, topics, subscriptions, authorization rules daily
Config-driven skip patterns
Does NOT sync messages — complements Geo-Replication

**Implementation**
What Has Been Done
1. Config Sync Pipeline (PR Raised)
Three files added to repo on branch 75802-BCP-Servicebus:

File	Purpose
.github/workflows/sync-bcp-servicebus.yaml	Daily scheduled workflow, plan/apply pattern
configs/sb-sync/bcp-sb-skip-patterns.yml	Namespace pairs and skip patterns
scripts/sb-sync/sync-prd-to-bcp-sb.py	Python sync script

How it works:

Runs daily at 2AM automatically
Plan job always runs first (dry-run preview, no changes)
Apply job requires APPROVE_SERVICEBUS environment approval before executing
Syncs queues, topics, subscriptions and authorization rules from PRD to BCP
Full audit trail via GitHub Actions artifacts
2. BCP Private Endpoint
Confirmed pre-existing: azuscshdbcpsbns01-pep
Location: Central US
Subnet: sdtBCP-subnet (designated PrivateEndpoints subnet)
Status: Succeeded / Approved 

Pending Items


Create privatelink.servicebus.windows.net DNS zone		Pending
Link DNS zone to BCP VNet (AZ-CUS-TAX-BCP-SDT-VNET-01)		Pending
Create APPROVE_SERVICEBUS GitHub environment with approvers	Pending
PR review and approval	Prashant	Pending
Enable Geo-Replication (after DNS ready + Prashant approval)		Pending
Geo-Replication Enablement (Post DNS Setup)
Once DNS zone is created and linked, the following command will enable Geo-Replication:


az servicebus namespace geo-data-replication create \
  --namespace-name azuse2shdprdsbns01 \
  --resource-group AZRG-USE2-TAX-SHD-PRD \
  --subscription c2501773-e73a-4552-927c-1a61e3370821 \
  --partner-namespace /subscriptions/c2501773-e73a-4552-927c-1a61e3370821/resourceGroups/AZRG-USC-TAX-SHD-BCP/providers/Microsoft.ServiceBus/namespaces/azuscshdbcpsbns01
Note:  approval required before running this command on PRD namespace.

Why In-Flight Messages Cannot Be Manually Synced
Service Bus messages are stored in an internal proprietary format managed entirely by Azure. There is no API or CLI command to read and copy messages between namespaces. The only supported way to replicate messages is via native Azure Geo-Replication — which is exactly what we are enabling.

Architecture Summary

PRD (East US 2)                          BCP (Central US)
azuse2shdprdsbns01                       azuscshdbcpsbns01
       |                                        |
azuse2shdprdsbns01-pep (Private EP) ←→ azuscshdbcpsbns01-pep (Private EP)
       |                                        |
AZ-EUS2-TAX-PRD-SDT-VNET-01            AZ-CUS-TAX-BCP-SDT-VNET-01
       |                                        |
       └──── Geo-Replication (pending DNS) ─────┘
       |                                        |
       └──── Config Sync Pipeline (daily 2AM) ──┘

References
ADO Task: 75802
Branch: 75802-BCP-Servicebus
Subscription: c2501773-e73a-4552-927c-1a61e3370821
