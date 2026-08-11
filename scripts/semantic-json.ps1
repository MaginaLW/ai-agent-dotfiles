#requires -Version 7.0

Set-StrictMode -Version Latest

$script:SemanticJsonMaxSafeInteger = [long] 9007199254740991
$script:SemanticJsonUtf8 = [System.Text.UTF8Encoding]::new($false)
$script:SemanticJsonEncoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping

function ConvertFrom-SemanticJsonElement {
    param([Parameter(Mandatory)] [System.Text.Json.JsonElement] $Element)

    switch ($Element.ValueKind) {
        ([System.Text.Json.JsonValueKind]::Object) {
            $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            $result = [ordered]@{}
            foreach ($property in $Element.EnumerateObject()) {
                if (-not $seen.Add($property.Name)) { throw "Semantic JSON contains duplicate property '$($property.Name)'." }
                $result[$property.Name] = ConvertFrom-SemanticJsonElement -Element $property.Value
            }
            return $result
        }
        ([System.Text.Json.JsonValueKind]::Array) {
            $items = @($Element.EnumerateArray() | ForEach-Object { ConvertFrom-SemanticJsonElement -Element $_ })
            Write-Output -NoEnumerate $items
            return
        }
        ([System.Text.Json.JsonValueKind]::String) { return $Element.GetString() }
        ([System.Text.Json.JsonValueKind]::True) { return $true }
        ([System.Text.Json.JsonValueKind]::False) { return $false }
        ([System.Text.Json.JsonValueKind]::Null) { return $null }
        ([System.Text.Json.JsonValueKind]::Number) {
            $raw = $Element.GetRawText()
            if ($raw -notmatch '^-?(0|[1-9][0-9]*)$') { throw "Semantic JSON accepts integer spellings only; fractions and exponents are forbidden: $raw" }
            $value = 0L
            if (-not [long]::TryParse($raw, [System.Globalization.NumberStyles]::AllowLeadingSign, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $value)) {
                throw "Semantic JSON integer is outside the supported range: $raw"
            }
            if ($value -lt -$script:SemanticJsonMaxSafeInteger -or $value -gt $script:SemanticJsonMaxSafeInteger) {
                throw "Semantic JSON integer is outside the I-JSON safe range: $raw"
            }
            return $value
        }
        default { throw "Unsupported Semantic JSON token: $($Element.ValueKind)" }
    }
}

function ConvertFrom-SemanticJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Json)

    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.AllowTrailingCommas = $false
    $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Json, $options)
    }
    catch {
        throw "Semantic JSON parse failed: $($_.Exception.Message)"
    }
    try { return ConvertFrom-SemanticJsonElement -Element $document.RootElement }
    finally { $document.Dispose() }
}

function Write-SemanticJsonValue {
    param(
        [AllowNull()] [object] $Value,
        [Parameter(Mandatory)] [System.Text.StringBuilder] $Builder
    )

    if ($null -eq $Value) { $null = $Builder.Append('null'); return }
    if ($Value -is [bool]) { $null = $Builder.Append($(if ($Value) { 'true' } else { 'false' })); return }
    if ($Value -is [string] -or $Value -is [char]) {
        $options = [System.Text.Json.JsonSerializerOptions]::new()
        $options.Encoder = $script:SemanticJsonEncoder
        $null = $Builder.Append([System.Text.Json.JsonSerializer]::Serialize([string] $Value, $options))
        return
    }

    $integerTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
    if ($Value.GetType() -in $integerTypes) {
        try { $number = [long] $Value }
        catch { throw "Semantic JSON integer is outside the supported range: $Value" }
        if ($number -lt -$script:SemanticJsonMaxSafeInteger -or $number -gt $script:SemanticJsonMaxSafeInteger) {
            throw "Semantic JSON integer is outside the I-JSON safe range: $Value"
        }
        $null = $Builder.Append($number.ToString([System.Globalization.CultureInfo]::InvariantCulture))
        return
    }
    if ($Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        throw 'Semantic JSON forbids floating-point and decimal values.'
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $keys = [System.Collections.Generic.List[string]]::new()
        $byName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        foreach ($key in $Value.Keys) {
            if ($key -isnot [string]) { throw 'Semantic JSON object property names must be strings.' }
            if (-not $byName.TryAdd([string] $key, $Value[$key])) { throw "Semantic JSON contains duplicate property '$key'." }
            $keys.Add([string] $key)
        }
        $keys.Sort([System.StringComparer]::Ordinal)
        $null = $Builder.Append('{')
        for ($index = 0; $index -lt $keys.Count; $index++) {
            if ($index -gt 0) { $null = $Builder.Append(',') }
            Write-SemanticJsonValue -Value $keys[$index] -Builder $Builder
            $null = $Builder.Append(':')
            Write-SemanticJsonValue -Value $byName[$keys[$index]] -Builder $Builder
        }
        $null = $Builder.Append('}')
        return
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $table = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.MemberType -in @('NoteProperty', 'Property', 'AliasProperty', 'ScriptProperty')) {
                $table[$property.Name] = $property.Value
            }
        }
        Write-SemanticJsonValue -Value $table -Builder $Builder
        return
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $null = $Builder.Append('[')
        $first = $true
        foreach ($item in $Value) {
            if (-not $first) { $null = $Builder.Append(',') }
            Write-SemanticJsonValue -Value $item -Builder $Builder
            $first = $false
        }
        $null = $Builder.Append(']')
        return
    }
    throw "Unsupported Semantic JSON value type: $($Value.GetType().FullName)"
}

function ConvertTo-SemanticJsonBytes {
    [CmdletBinding()]
    param([AllowNull()] [object] $InputObject)

    $builder = [System.Text.StringBuilder]::new()
    Write-SemanticJsonValue -Value $InputObject -Builder $builder
    return $script:SemanticJsonUtf8.GetBytes($builder.ToString())
}

function Get-SemanticJsonHash {
    [CmdletBinding(DefaultParameterSetName = 'Object')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Object')] [AllowNull()] [object] $InputObject,
        [Parameter(Mandatory, ParameterSetName = 'Path')] [string] $Path
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $json = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, [System.Text.UTF8Encoding]::new($false, $true))
        $InputObject = ConvertFrom-SemanticJson -Json $json
    }
    $bytes = ConvertTo-SemanticJsonBytes -InputObject $InputObject
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-PlanHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $PlanPayload)
    return Get-SemanticJsonHash -InputObject $PlanPayload
}

function Get-DocumentHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Document)

    $source = if ($Document -is [System.Collections.IDictionary]) { $Document } else {
        $table = [ordered]@{}
        foreach ($property in $Document.PSObject.Properties) { $table[$property.Name] = $property.Value }
        $table
    }
    $copy = [ordered]@{}
    foreach ($key in $source.Keys) {
        if ([string] $key -ceq 'DocumentHash') { continue }
        $copy[[string] $key] = $source[$key]
    }
    return Get-SemanticJsonHash -InputObject $copy
}
