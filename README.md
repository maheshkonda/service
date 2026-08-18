Servicebus-SOP
Azure Service Bus BCP Strategy:

Azure Service Bus Geo-Replication follows an Active-Passive architecture.

The Primary Service Bus Namespace handles all producer and consumer traffic while continuously replicating to the Secondary (BCP) region. During a planned failover or regional outage, the Secondary region is promoted to Primary. Once the original Primary region is restored, a planned failback promotes it back to Primary, automatically reversing the replication direction and restoring the original Active-Passive topology.

Data Synchronization Approach:

Primary → BCP

The Primary Service Bus Namespace continuously replicates to the Secondary (BCP) region using Azure Service Bus Geo-Replication.

Primary region handles all producer and consumer traffic.
Secondary region remains synchronized and in Ready state.
Prior to failover, verify:


Replica State = Ready
Replication Lag = 0 seconds
BCP → Primary (Backward Sync After Failover):

After failover, the BCP region becomes the new Primary and begins serving all producer and consumer traffic.
Once the original Primary region is restored:

Perform a Planned Promotion (Failback).
Geo-Replication automatically reverses the replication direction.
The original region resumes as Primary.
The BCP region returns to the Secondary role.
Applications continue using the same Service Bus Namespace FQDN throughout failover and failback.

Testing Evidence:

Dev Environment Testing

Step	Action	Status
1	Deployed Private Endpoints for sbns01 and sbns02 on dev environment (no DNS zone group)	✅ Done
2	Updated AKS CoreDNS configmap (azure-hosts.override) with PE IPs on dev AKS cluster	✅ Done
3	From dev AKS test pod, validated DNS resolution (nslookup) — sbns01 resolved to 10.202.24.152, sbns02 resolved to 10.202.24.193 via privatelink.servicebus.windows.net	✅ Done
4	Validate connectivity (nc/telnet) on ports 443 and 5671 from dev AKS pod	⏳ Pending
Note: Connectivity is our responsibility — data replication is managed by Microsoft (Azure native geo-replication).

FAILOVER SOP

PROD → BCP

Step	Action
1	Verify production region issue or approved DR activity and confirm failover is required.
2	Verify Geo-Replication health (Replica State = Ready, Replication Lag within acceptable limits).
3	Navigate to Azure Portal → Service Bus Namespace → Geo-replication → Initiate Planned promotion of the BCP region.
4	Verify BCP becomes Primary.
5	Validate application connectivity from BCP AKS cluster.
6	Publish and verify a test message using Service Bus Explorer (or application validation).
BCP → PROD

Step	Action
1	Confirm the original Production region is healthy and synchronized.
2	Verify Geo-Replication Synchronization health (Replica State = Ready, Replication Lag within acceptable limits).
3	Initiate planned promotion back to Prod and verify Prod becomes Primary.
4	Validate application connectivity.
5	Publish and verify a test message to confirm backward synchronization.
6	Confirm applications continue processing successfully and notify failback is complete.
Dev Service Bus Namespaces:

Namespace	PE Name	Private IP
azuscshddevsbns01	azuscshddevsbns01-pep	10.202.24.152
azuscshddevsbns02	azuscshddevsbns02-pep	10.202.24.193
Important Notes:

Failover cooldown period: minimum 1 hour before failback can be initiated
Connectivity is our responsibility — data replication is managed by Microsoft
Private endpoints must be deployed without DNS zone group integration for CoreDNS override to work
CoreDNS configmap must use azure-hosts.override key — only 1 hosts definition supported in coredns-custom
All host entries must be merged into a single azure-hosts.override block — separate blocks will break CoreDNS for the entire cluster
