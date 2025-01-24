$hiraganaMap = Get-Content -Raw -Path "hiragana_ascii_map.json" | ConvertFrom-Json

$stats = @{
    Total = 0
    Correct = 0
    History = @{}
    SeenOrder = @()  # Array of characters in order they were seen
}

function Load-Stats {
    $statsFile = "hiragana_stats.json"
    if (Test-Path $statsFile) {
        $loadedStats = Get-Content -Raw $statsFile | ConvertFrom-Json
        
        $script:stats = @{
            Total = [int]$loadedStats.Total
            Correct = [int]$loadedStats.Correct
            History = @{}
            SeenOrder = @()
        }
        
        if ($loadedStats.PSObject.Properties.Name -contains 'History') {
            foreach ($prop in $loadedStats.History.PSObject.Properties) {
                $script:stats.History[$prop.Name] = @{
                    Attempts = [int]$prop.Value.Attempts
                    Correct = [int]$prop.Value.Correct
                }
            }
        }

        if ($loadedStats.PSObject.Properties.Name -contains 'SeenOrder') {
            $script:stats.SeenOrder = $loadedStats.SeenOrder
        }
        
        Write-Host "Previous stats loaded!" -ForegroundColor Green
    } else {
        $script:stats = @{
            Total = 0
            Correct = 0
            History = @{}
            SeenOrder = @()
        }
        Write-Host "No previous stats found. Starting fresh!" -ForegroundColor Yellow
    }
}

function Save-Stats {
    $statsFile = "hiragana_stats.json"
    $stats | ConvertTo-Json | Set-Content $statsFile
    Write-Host "Stats saved!" -ForegroundColor Green
}

function Update-SeenOrder {
    param (
        [string]$romaji
    )
    
    # Remove if exists
    $stats.SeenOrder = $stats.SeenOrder | Where-Object { $_ -ne $romaji }
    # Add to front
    $stats.SeenOrder = @($romaji) + $stats.SeenOrder
}

function Update-Stats {
    param (
        [string]$romaji,
        [bool]$isCorrect
    )
    
    $stats.Total++
    if ($isCorrect) { $stats.Correct++ }
    
    if (-not $stats.History.ContainsKey($romaji)) {
        $stats.History[$romaji] = @{
            Attempts = 0
            Correct = 0
        }
    }
    
    $stats.History[$romaji].Attempts++
    if ($isCorrect) { $stats.History[$romaji].Correct++ }
    
    Update-SeenOrder -romaji $romaji
}

function Show-FocusedStats {
    param (
        [string]$currentRomaji
    )
    
    $accuracy = if ($stats.Total -gt 0) { ($stats.Correct / $stats.Total).ToString("P") } else { "0%" }
    Write-Host "`nOverall Statistics:" -ForegroundColor Cyan
    Write-Host "Total Attempts: $($stats.Total)"
    Write-Host "Correct Answers: $($stats.Correct)"
    Write-Host "Accuracy: $accuracy"
    
    if ($stats.History.Count -gt 0) {
        # Calculate accuracy for each character
        $charStats = @()
        foreach ($entry in $stats.History.GetEnumerator()) {
            if ($entry.Value.Attempts -ge 1) {
                $charStats += @{
                    Character = $entry.Key
                    Accuracy = [math]::Round($entry.Value.Correct / $entry.Value.Attempts, 4)
                    Attempts = $entry.Value.Attempts
                    Stats = "$($entry.Value.Correct)/$($entry.Value.Attempts)"
                }
            }
        }
        
        # Best performing (sorted by accuracy then number of attempts)
        Write-Host "`nBest Performing:" -ForegroundColor Green
        $charStats | 
            Where-Object { -not ($_.Accuracy -eq 0) } |
            Sort-Object { $_.Accuracy }, { $_.Attempts } -Descending |
            Select-Object -First 3 |
            ForEach-Object {
                Write-Host "$($_.Character): $($_.Accuracy.ToString("P")) ($($_.Stats))"
            }
        
        # Needs practice (show actual lowest performing, exclude 100%)
        Write-Host "`nNeeds Practice:" -ForegroundColor Red
        $charStats | 
            Where-Object { $_.Accuracy -lt 1 } |
            Sort-Object { $_.Accuracy }, { -$_.Attempts } |
            Select-Object -First 3 |
            ForEach-Object {
                Write-Host "$($_.Character): $($_.Accuracy.ToString("P")) ($($_.Stats))"
            }
        
        if ($currentRomaji) {
            $currentStats = $stats.History[$currentRomaji]
            $currentAccuracy = ($currentStats.Correct / $currentStats.Attempts).ToString("P")
            
            Write-Host "`nCurrent Character:" -ForegroundColor Yellow
            Write-Host "$($currentRomaji): $currentAccuracy ($($currentStats.Correct)/$($currentStats.Attempts))"
        }
    }
}

function Edit-LastAnswer {
    param (
        [string]$romaji,
        [bool]$originalIsCorrect
    )
    
    Write-Host "`nCurrent record for '$romaji' was marked as: " -NoNewline
    Write-Host $(if ($originalIsCorrect) { "Correct" } else { "Incorrect" }) -ForegroundColor $(if ($originalIsCorrect) { "Green" } else { "Red" })
    
    $response = Read-Host "Would you like to mark it as" $(if ($originalIsCorrect) { "incorrect" } else { "correct" }) "instead? (y/n)"
    
    if ($response.ToLower() -eq 'y') {
        # Undo the previous stats update
        $stats.Total--
        if ($originalIsCorrect) { $stats.Correct-- }
        $stats.History[$romaji].Attempts--
        if ($originalIsCorrect) { $stats.History[$romaji].Correct-- }
        
        # Update with the corrected answer
        Update-Stats -romaji $romaji -isCorrect (-not $originalIsCorrect)
        
        Write-Host "Record updated!" -ForegroundColor Green
    }
}

function Get-NextCharacter {
    $availableRomaji = $hiraganaMap | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
    $charScores = @{}
    
    # Get min and max attempts for normalization
    $minAttempts = [int]::MaxValue
    $maxAttempts = 0
    
    foreach ($romaji in $availableRomaji) {
        if ($stats.History.ContainsKey($romaji)) {
            $attempts = $stats.History[$romaji].Attempts
            if ($attempts -gt 0) {
                $minAttempts = [Math]::Min($minAttempts, $attempts)
                $maxAttempts = [Math]::Max($maxAttempts, $attempts)
            }
        }
    }
    
    if ($minAttempts -eq [int]::MaxValue) {
        $minAttempts = 0
    }
    
    foreach ($romaji in $availableRomaji) {
        # Initialize score components
        $accuracyWeight = 0
        $attemptWeight = 0
        $lastSeenWeight = 0
        
        if ($stats.History.ContainsKey($romaji)) {
            $history = $stats.History[$romaji]
            
            if ($history.Attempts -gt 0) {
                # Accuracy weight (0-45 points)
                $accuracy = $history.Correct / $history.Attempts
                $accuracyWeight = (1 - $accuracy) * 45
                
                # Attempt weight (0-30 points)
                if ($maxAttempts -gt $minAttempts) {
                    $attemptWeight = 30 * (($maxAttempts - $history.Attempts) / ($maxAttempts - $minAttempts))
                }
            }
        } else {
            # Never attempted characters get high priority
            $accuracyWeight = 40
            $attemptWeight = 30
        }
        
        # Last seen weight (0-25 points)
        $seenIndex = $stats.SeenOrder.IndexOf($romaji)
        if ($seenIndex -eq -1) {
            # Never seen gets max weight
            $lastSeenWeight = 25
        } else {
            # The further back in the list, the higher the weight
            $lastSeenWeight = 25 * ($seenIndex / [Math]::Max(1, $stats.SeenOrder.Count - 1))
        }
        
        $baseScore = $accuracyWeight + $attemptWeight + $lastSeenWeight
        
        # Apply random scalar (0.8 to 1.2)
        $randomFactor = 0.8 + (Get-Random -Minimum 0 -Maximum 401) / 1000
        $totalScore = $baseScore * $randomFactor
        
        $charScores[$romaji] = $totalScore
    }
    
    # Select character with highest score
    $selectedChar = $charScores.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    
    return $selectedChar.Key
}

function Show-HiraganaFlashcard {
    $correctRomaji = Get-NextCharacter
    
    Write-Host "`nWhat is this hiragana character?`n"
    Write-Host $hiraganaMap.$correctRomaji.ascii
    Write-Host "`n"
    
    $userAnswer = Read-Host "Enter the romaji"
    
    $isCorrect = $userAnswer.ToLower().trim() -eq $correctRomaji
    Update-Stats -romaji $correctRomaji -isCorrect $isCorrect
    
    if ($isCorrect) {
        Write-Host "Correct!" -ForegroundColor Green
    } else {
        Write-Host "Incorrect. The answer was '$correctRomaji'" -ForegroundColor Red
    }
    
    Show-FocusedStats -currentRomaji $correctRomaji
    
    # Return information about this answer
    return @{
        Romaji = $correctRomaji
        IsCorrect = $isCorrect
    }
}

function Start-FlashcardSession {
    Clear-Host
    Load-Stats
    $lastRomaji = $null
    $lastIsCorrect = $false
    
    while ($true) {
        $flashcardResult = Show-HiraganaFlashcard
        $lastRomaji = $flashcardResult.Romaji
        $lastIsCorrect = $flashcardResult.IsCorrect
        
        Write-Host "`nPress Enter to continue, 'e' to edit last answer, or 'q' to quit"
        $continue = Read-Host
        
        switch ($continue.ToLower()) {
            'e' {
                Edit-LastAnswer -romaji $lastRomaji -originalIsCorrect $lastIsCorrect
                Save-Stats  # Save after editing
                Write-Host "`nPress Enter to continue or 'q' to quit"
                $continue = Read-Host
                if ($continue -eq 'q') {
                    Save-Stats
                    return
                }
            }
            'q' { 
                Save-Stats
                return 
            }
        }
        Clear-Host
        Save-Stats  # Save after each answer
    }
}

# Start the flashcard session
Start-FlashcardSession