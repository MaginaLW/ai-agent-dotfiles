#requires -Version 7.0

# Phase 1 production recovery Apply remains interlocked. This reviewed engine
# is test-only and is loaded explicitly by isolated suites and sealed hosts.
if (-not (Get-Command Get-CanonicalTransactionRecoveryClassification -ErrorAction SilentlyContinue)) {
    throw 'Load scripts/canonical-recovery-common.ps1 before the sealed recovery engine.'
}

if (-not ('AiAgentDotfilesTests.SealedRecoveryStageCoordinator' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace AiAgentDotfilesTests {
    public sealed class SealedRecoveryStageCoordinator : IDisposable {
        private readonly string stageRoot;
        private readonly string stopAfterTargetId;
        private readonly EventWaitHandle continueEvent;
        private readonly int waitMilliseconds;
        private int sequence;
        private bool disposed;

        public SealedRecoveryStageCoordinator(string stageRoot, string stopAfterTargetId, string eventName, int waitMilliseconds) {
            if (String.IsNullOrWhiteSpace(stageRoot)) throw new ArgumentException("A recovery stage root is required.", "stageRoot");
            if (!Regex.IsMatch(stopAfterTargetId ?? String.Empty, "^[0-9a-f]{64}$", RegexOptions.CultureInvariant)) throw new ArgumentException("The stop target id is invalid.", "stopAfterTargetId");
            if (String.IsNullOrWhiteSpace(eventName)) throw new ArgumentException("A recovery stage event name is required.", "eventName");
            if (waitMilliseconds <= 0) throw new ArgumentOutOfRangeException("waitMilliseconds");
            this.stageRoot = Path.GetFullPath(stageRoot);
            if (!Directory.Exists(this.stageRoot)) throw new DirectoryNotFoundException("The recovery stage root does not exist: " + this.stageRoot);
            this.stopAfterTargetId = stopAfterTargetId;
            this.continueEvent = EventWaitHandle.OpenExisting(eventName);
            this.waitMilliseconds = waitMilliseconds;
        }

        private void PublishTargetStage(string stage, string targetId, long order, string targetKind) {
            if (disposed) throw new ObjectDisposedException("SealedRecoveryStageCoordinator");
            if (!String.Equals(stage, "entering", StringComparison.Ordinal) && !String.Equals(stage, "visited", StringComparison.Ordinal)) throw new ArgumentException("The recovery target stage is invalid.", "stage");
            if (!Regex.IsMatch(targetId ?? String.Empty, "^[0-9a-f]{64}$", RegexOptions.CultureInvariant)) throw new ArgumentException("The visited target id is invalid.", "targetId");
            if (order < 0) throw new ArgumentOutOfRangeException("order");
            if (!Regex.IsMatch(targetKind ?? String.Empty, "^(?:file|directory|parent-directory)$", RegexOptions.CultureInvariant)) throw new ArgumentException("The visited target kind is invalid.", "targetKind");

            int visitedSequence = checked(++sequence);
            string leaf = stage + "-" + visitedSequence.ToString("D6", System.Globalization.CultureInfo.InvariantCulture) + ".json";
            string finalPath = Path.Combine(stageRoot, leaf);
            string tempPath = Path.Combine(stageRoot, "." + leaf + "." + Guid.NewGuid().ToString("N") + ".tmp");
            string json = "{\"SchemaVersion\":1,\"ArtifactKind\":\"sealed-recovery-target-stage\",\"Stage\":\"" + stage + "\",\"Sequence\":" +
                visitedSequence.ToString(System.Globalization.CultureInfo.InvariantCulture) + ",\"TargetId\":\"" + targetId +
                "\",\"Order\":" + order.ToString(System.Globalization.CultureInfo.InvariantCulture) + ",\"TargetKind\":\"" + targetKind + "\"}";
            byte[] bytes = new UTF8Encoding(false, true).GetBytes(json);
            bool published = false;
            try {
                using (FileStream stream = new FileStream(tempPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough)) {
                    stream.Write(bytes, 0, bytes.Length);
                    stream.Flush(true);
                }
                File.Move(tempPath, finalPath, false);
                published = true;
            }
            finally {
                if (!published && File.Exists(tempPath)) File.Delete(tempPath);
            }

            if (String.Equals(targetId, stopAfterTargetId, StringComparison.Ordinal) && !continueEvent.WaitOne(waitMilliseconds)) {
                throw new TimeoutException("Timed out waiting to continue sealed recovery after target " + targetId + ".");
            }
        }

        public void PublishEnteringTarget(string targetId, long order, string targetKind) { PublishTargetStage("entering", targetId, order, targetKind); }
        public void PublishVisitedTarget(string targetId, long order, string targetKind) { PublishTargetStage("visited", targetId, order, targetKind); }

        public void Dispose() {
            if (disposed) return;
            disposed = true;
            continueEvent.Dispose();
        }
    }
}
'@
}

function Invoke-SealedCanonicalReviewedRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowNull()][AiAgentDotfilesTests.SealedRecoveryStageCoordinator]$BeforeRestoreStageCoordinator,
        [AllowNull()][AiAgentDotfilesTests.SealedRecoveryStageCoordinator]$AfterRestoreStageCoordinator
    )
    $null=Assert-CanonicalRecoveryStateContext -State $State -RepoRoot $RepoRoot
    $action=[string]$Document.PlanPayload.PlannedAction
    $classification=Get-CanonicalTransactionRecoveryClassification -State $State -RepoRoot $RepoRoot
    if([string]$classification.AllowedAction -cne $action){throw 'canonical-recovery-action-mismatch'}
    if([string]$Document.DocumentHash -in @($State.ConsumedDocumentHashes)){throw 'reviewed-plan-consumed'}
    $null=Add-CanonicalJournalRecord -TransactionNamespace $State.TransactionNamespace -Phase RECOVERY_ACTION_INTENT -Data ([ordered]@{
        PlanKind=[string]$Document.PlanPayload.PlanKind;DocumentHash=[string]$Document.DocumentHash;PriorHeadHash=[string]$State.DerivedJournalHeadHash;ExpectedOutcome=[string]$Document.PlanPayload.ExpectedOutcome;ExpectedTerminalProjectionHash=[string]$Document.PlanPayload.ExpectedTerminalProjectionHash
    })
    if($action -eq 'rollback'){
        $current=Get-CanonicalJournalStateForAppend -TransactionNamespace $State.TransactionNamespace
        foreach($target in @($current.Header.Targets|Sort-Object{[long]$_.Order} -Descending)){
            $reconciliation=Get-CanonicalTargetReconciliation -Target $target -Records @($current.Records)
            if($BeforeRestoreStageCoordinator){
                $BeforeRestoreStageCoordinator.PublishEnteringTarget([string]$target.TargetId,[long]$target.Order,[string]$target.TargetKind)
            }
            Restore-CanonicalMutationTarget -Target $target -Reconciliation $reconciliation
            if($AfterRestoreStageCoordinator){
                $AfterRestoreStageCoordinator.PublishVisitedTarget([string]$target.TargetId,[long]$target.Order,[string]$target.TargetKind)
            }
        }
    }elseif($action -eq 'finalize' -and [string]$State.Header.CanonicalOperationKind -ceq 'setup' -and $classification.PSObject.Properties['SetupState'] -and $classification.SetupState){
        $null=Publish-CanonicalSetupFinalStateForRecovery -State $State -Classification $classification
    }
    $null=Add-CanonicalJournalRecord -TransactionNamespace $State.TransactionNamespace -Phase RECOVERY_ACTION_APPLIED -Data ([ordered]@{Action=$action;DocumentHash=[string]$Document.DocumentHash})
    $afterAction=Get-CanonicalJournalStateForAppend -TransactionNamespace $State.TransactionNamespace
    $null=Assert-CanonicalRecoveryOutcomeReady -State $afterAction -RepoRoot $RepoRoot -ExpectedOutcome ([string]$Document.PlanPayload.ExpectedOutcome)
    $result=$afterAction.Result
    if($result){
        $projection=Get-CanonicalTransactionResultProjection -Result $result
        if((Get-SemanticJsonHash -InputObject $projection) -cne [string]$Document.PlanPayload.ExpectedTerminalProjectionHash){throw 'manual-recovery-required: existing fixed result differs from reviewed projection'}
        $resultHash=[string]$afterAction.ResultHash
    }else{
        $projection=$Document.PlanPayload.ExpectedTerminalProjection
        $resultDocument=[ordered]@{}
        foreach($name in $projection.Keys){$resultDocument[$name]=$projection[$name]}
        $resultDocument.Insert(7,'ResultBaseHeadHash',[string]$afterAction.DerivedJournalHeadHash)
        $published=Publish-CanonicalTransactionResult -TransactionNamespace $State.TransactionNamespace -Document $resultDocument
        $resultHash=[string]$published.Hash
    }
    $beforeComplete=Get-CanonicalJournalStateForAppend -TransactionNamespace $State.TransactionNamespace
    $null=Assert-CanonicalRecoveryOutcomeReady -State $beforeComplete -RepoRoot $RepoRoot -ExpectedOutcome ([string]$Document.PlanPayload.ExpectedOutcome)
    $null=Add-CanonicalJournalRecord -TransactionNamespace $State.TransactionNamespace -Phase COMPLETE -Data ([ordered]@{
        ResultHash=$resultHash;OriginalDocumentHash=[string]$State.Header.OriginalDocumentHash;Outcome=[string]$Document.PlanPayload.ExpectedOutcome
        ClosingKind='recovery';ClosingDocumentHash=[string]$Document.DocumentHash;ClosingPlanKind=[string]$Document.PlanPayload.PlanKind
    })
    return Read-CanonicalJournalDirectory -TransactionNamespace $State.TransactionNamespace
}
