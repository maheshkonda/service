My Recommendation: Option 2 
Why Not Option 1 (Full Premium Both Sides)
Paying ~$1,336/month for a BCP namespace that sits idle 99% of the time is hard to justify to a client. Deloitte bills clients for infrastructure costs and an idle Premium Service Bus is a very visible line item that will get questioned in every quarterly review.

Why Not Option 3 (Spin Up on Failover)
Too risky. Creating infrastructure during an actual outage when the team is already under pressure is a recipe for mistakes. RTO of 90 minutes is too long for a tax processing platform where clients are submitting time-sensitive documents.

Why Not Option 4 (Active-Active)
Complete application redesign required. The TTO microservices are not built for duplicate message handling. This is a 6-12 month project, not a BCP task.

My Proposed Approach: Warm Standby with Automated Promotion
Normal Operations

PRD:  2x Premium namespaces    - East US 2    - fully active
BCP:  2x Standard namespaces   - Central US   - warm standby
BCP Standard costs near zero at idle. All entity configuration — queues, topics, subscriptions — deployed to BCP Standard via existing pipeline automation. BCP stays current with PRD configuration at all times via the pipeline.

Why Standard on BCP is Actually Fine
The manager was right. Nobody uses BCP 99% of the time. Standard tier gives you:

Full topics and subscriptions support
All the same entity types as Premium
Enough capacity to handle traffic during a regional outage
Near zero cost at idle
What you lose vs Premium:

No Geo-DR alias — acceptable, we handle this via pipeline
No VNet integration — needs to be evaluated against BCP network config
No dedicated resources — acceptable for BCP scenario
256KB message limit vs 100MB — need to verify TTO message sizes
The Twist — Pre-Validated Upgrade Runbook
Instead of upgrading on the fly during an outage, we pre-validate the upgrade process monthly in UAT:


Monthly drill:
1. Upgrade UAT Standard --> Premium (timed)
2. Verify all entities present
3. Test failover command
4. Document time taken
5. Keep as Premium for 24 hours
6. Delete and recreate as Standard
7. Update runbook with actual timings
This means when a real outage happens:

Team has done this 12 times before
Exact time to upgrade is known
No surprises during actual DR event
RTO is predictable and documented
Failover Sequence During Actual Outage

Time 0:    East US 2 outage declared
Time 0-5:  BCP authority approval gate
Time 5-20: Upgrade BCP Standard --> Premium
Time 20-25: Verify all entities present in BCP
Time 25-30: App team points connection strings to BCP
Time 30-35: Smoke tests pass
Time 35:   BCP live
Predicted RTO: 35 minutes

Cost Comparison
Option 1	My Proposal	Saving
PRD monthly	$1,336	$1,336	$0
BCP monthly	$1,336	~$20	$1,316
Annual saving	-	-	$15,792/year
RTO	Minutes	35 mins	Acceptable tradeoff
$15,792 saved per year for a 35 minute RTO on an event that may never happen. For Deloitte this is an easy sell to the client.

One Condition — Must Verify
Before committing to Standard on BCP we need to verify one thing:

TTO message sizes must be under 256KB

Standard tier has a 256KB message limit. Premium allows 100MB. If any TTO service sends messages larger than 256KB — for example embedding document content in messages — Standard will not work and we have no choice but Premium on both sides.

Run this to check:


az servicebus namespace show \
  --name azuse2shdprdsbns01 \
  --resource-group AZRG-USE2-TAX-SHD-PRD \
  --query "maximumThroughputUnits" \
  --output table
And ask the app team specifically:

"Do any of your Service Bus messages carry binary content or document payloads, or are they purely lightweight JSON event notifications?"

If the answer is lightweight JSON — Standard is fine and we save $15,792 a year.

Summary

Normal:   PRD Premium + BCP Standard
Failover: Upgrade BCP to Premium (pre-validated monthly)
RTO:      35 minutes
Saving:   $15,792/year
Risk:     Low - monthly drills keep team sharp
This is the option I would present to the client. It is cost responsible, operationally sound, and defensible in any architecture review.
