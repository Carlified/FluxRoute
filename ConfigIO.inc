// Placement config editing, validation and project persistence (save/open,
// recent projects) UI. Included from MainWindow's implementation via
// {$I ConfigIO.inc}.

procedure TForm1.UpdateRecentList;
var
  i: Integer;
begin
  ListBoxRecent.Clear;
  for i := 0 to FRecent.Count - 1 do
    ListBoxRecent.Items.Add(FRecent[i]);
end;

procedure TForm1.RemoveRecentProject(const Path: string);
var
  Idx: Integer;
begin
  Idx := FRecent.IndexOf(Path);
  if Idx < 0 then
    Exit;
  FRecent.Delete(Idx);
  // The recent-projects file is optional state (best-effort write): a failure
  // just means the list reverts on the next launch, so swallow it quietly.
  try
    SaveRecentProjects('', FRecent);
  except
  end;
  UpdateRecentList;
end;

function GcdOf(const A, B: Double): Double;
var
  AA, BB, R: Double;
begin
  AA := Abs(A);
  BB := Abs(B);
  if BB = 0 then
    Exit(AA);
  while BB > 1e-9 do
  begin
    R := AA - Trunc(AA / BB) * BB;
    AA := BB;
    BB := R;
  end;
  Result := AA;
end;

function IsMultipleOf(const A, B: Double): Boolean;
begin
  if B = 0 then
    Result := False
  else
    Result := Abs(A / B - Round(A / B)) < 1e-6;
end;

function DimToStr(const V: Double): string;
begin
  if Abs(V - Round(V)) < 1e-6 then
    Result := IntToStr(Round(V))
  else
    Result := FloatToStr(V);
end;

function TryDimParse(const S: string; out V: Double): Boolean;
begin
  V := 0;
  if Trim(S) = '' then
    Exit(False);
  Result := TryStrToFloat(S, V, TFormatSettings.Invariant);
end;

function FormatDim2(const V: Double): string;
begin
  Result := FormatFloat('0.00', V);
end;

procedure TForm1.InitializePlacementConfig;
var
  G, ModeH: Double;
  Cell: TCell;
  Key, BestKey, BestCount: Integer;
  Tally: TDictionary<Integer, Integer>;
  i: Integer;
begin
  G := 0;
  ModeH := 0;
  if (FLib <> nil) and (FLib.Cells.Count > 0) then
  begin
    for Cell in FLib.Cells do
      if Cell.Width > 0 then
        G := GcdOf(G, Cell.Width);

    // Mode of all cell heights (most common value), keyed on thousandths
    // so simple decimal sizes (0.5, 1.0, ...) group cleanly.
    Tally := TDictionary<Integer, Integer>.Create;
    try
      for Cell in FLib.Cells do
        if Cell.Height > 0 then
        begin
          Key := Round(Cell.Height * 1000);
          if Tally.ContainsKey(Key) then
            Tally[Key] := Tally[Key] + 1
          else
            Tally.Add(Key, 1);
        end;
      BestKey := -1;
      BestCount := 0;
      for Key in Tally.Keys do
        if Tally[Key] > BestCount then
        begin
          BestCount := Tally[Key];
          BestKey := Key;
        end;
      if BestKey >= 0 then
        ModeH := BestKey / 1000;
    finally
      Tally.Free;
    end;
  end;

  // Setting these fires OnChange, but the initial-guard flag is still off.
  EditCoreSize.Text := DimToStr(G);
  EditRowHeight.Text := DimToStr(ModeH);
  // Default die area to a single core block (G x G) as a starting point.
  EditDieW.Text := DimToStr(G);
  EditDieH.Text := DimToStr(G);
  // Placement budget defaults.
  EditUtilization.Text := '60';
  EditBiasCurrent.Text := '5';
  EditTrunkCurrent.Text := '20';
  EditPTLLength.Text := '550';
  EditFreqGHz.Text := '10';
  EditPTLDelay.Text := '10';
  EditPulseWidth.Text := '5';
  // Bias-routing layer: default to the first masterslice layer (the usual
  // choice for the bias rail, since it is not a signal-routing layer); leave
  // the current selection if one was already made.
  if ComboBiasLayer.ItemIndex < 0 then
  begin
    ComboBiasLayer.ItemIndex := 0;
    if FLib <> nil then
      for i := 0 to FLib.Layers.Count - 1 do
        if FLib.Layers[i].LayerType = ltMasterslice then
        begin
          ComboBiasLayer.ItemIndex := i;
          Break;
        end;
  end;
  FBiasLayer := '';
  if ComboBiasLayer.ItemIndex >= 0 then
    FBiasLayer := ComboBiasLayer.Items[ComboBiasLayer.ItemIndex];
  FPlacementInitialized := True;
  FormatPlacementFields;
  ValidatePlacement;
end;

procedure TForm1.FormatPlacementFields;
var
  Core, RowH, DieW, DieH: Double;
begin
  // Suppress OnChange while we rewrite the text boxes programmatically.
  FFormattingPlacement := True;
  try
    Core := -1;
    if TryDimParse(EditCoreSize.Text, Core) then
      EditCoreSize.Text := FormatDim2(Core);
    if TryDimParse(EditRowHeight.Text, RowH) then
      EditRowHeight.Text := FormatDim2(RowH);
    if TryDimParse(EditDieW.Text, DieW) then
      EditDieW.Text := FormatDim2(DieW);
    if TryDimParse(EditDieH.Text, DieH) then
      EditDieH.Text := FormatDim2(DieH);
    if TryDimParse(EditUtilization.Text, Core) then
      EditUtilization.Text := FormatDim2(Core);
    if TryDimParse(EditBiasCurrent.Text, Core) then
      EditBiasCurrent.Text := FormatDim2(Core);
    if TryDimParse(EditTrunkCurrent.Text, Core) then
      EditTrunkCurrent.Text := FormatDim2(Core);
    if TryDimParse(EditPTLLength.Text, Core) then
      EditPTLLength.Text := FormatDim2(Core);
    if TryDimParse(EditFreqGHz.Text, Core) then
      EditFreqGHz.Text := FormatDim2(Core);
    if TryDimParse(EditPTLDelay.Text, Core) then
      EditPTLDelay.Text := FormatDim2(Core);
    if TryDimParse(EditPulseWidth.Text, Core) then
      EditPulseWidth.Text := FormatDim2(Core);
  finally
    FFormattingPlacement := False;
  end;

  // Labels only update from the last successfully parsed values.
  if TryDimParse(EditCoreSize.Text, Core) then
    LabelCoreDim.Text := ' x ' + FormatDim2(Core) + ' um';
  if (Core > 0) and TryDimParse(EditRowHeight.Text, RowH) then
    LabelRowCells.Text := ' - ' + IntToStr(Round(RowH / Core)) + ' cells';
  if TryDimParse(EditDieW.Text, DieW) and TryDimParse(EditDieH.Text, DieH) then
    LabelDieAreaText.Text := FormatDim2(DieW * DieH) + ' um2';
end;

// Parses the placement/routing configuration text boxes once into FDesignConfig,
// so the algorithms read parsed values instead of re-parsing Edit*.Text.
procedure TForm1.RefreshDesignConfig;
var
  D: Double;
begin
  FDesignConfig := Default(TDesignConfig);
  if TryDimParse(EditCoreSize.Text, D) then FDesignConfig.CoreUm := D;
  if TryDimParse(EditRowHeight.Text, D) then FDesignConfig.RowHeightUm := D;
  if TryDimParse(EditDieW.Text, D) then FDesignConfig.DieWUm := D;
  if TryDimParse(EditDieH.Text, D) then FDesignConfig.DieHUm := D;
  if TryDimParse(EditUtilization.Text, D) then FDesignConfig.UtilizationPct := D;
  if TryDimParse(EditBiasCurrent.Text, D) then FDesignConfig.MaxBiasCurrentUa := D;
  if TryDimParse(EditTrunkCurrent.Text, D) then FDesignConfig.MaxBiasTrunkCurrentUa := D;
  if TryDimParse(EditPTLLength.Text, D) then FDesignConfig.MaxPtlLengthUm := D;
  if TryDimParse(EditFreqGHz.Text, D) then FDesignConfig.FreqGHz := D;
  // The field is entered in fs/um; the config and the exported tools use ps/um.
  if TryDimParse(EditPTLDelay.Text, D) then
    FDesignConfig.PtlDelayPsPerUm := D / 1000;
  if TryDimParse(EditPulseWidth.Text, D) then FDesignConfig.PulseWidthUm := D;
  FDesignConfig.BiasLayer := FBiasLayer;
end;

procedure TForm1.ValidatePlacement;
var
  Core, RowH, CellH, DieW, DieH, Util, Bias, PTL, TrunkUa: Double;
  Cell: TCell;
  Used: Boolean;
  UsedNames: TDictionary<string, Boolean>;
  Gate: TGateInstance;
  ErrMsgs, WarnMsgs: TStringList;
  i: Integer;
begin
  RefreshDesignConfig;
  ListBoxPlacementErrors.Clear;
  FPlacementErrorCount := 0;
  // Restore the default text colors before re-flagging invalid fields.
  EditRowHeight.StyledSettings := EditRowHeight.StyledSettings + [TStyledSetting.FontColor];
  EditDieW.StyledSettings := EditDieW.StyledSettings + [TStyledSetting.FontColor];
  EditDieH.StyledSettings := EditDieH.StyledSettings + [TStyledSetting.FontColor];
  EditUtilization.StyledSettings := EditUtilization.StyledSettings + [TStyledSetting.FontColor];
  EditTrunkCurrent.StyledSettings := EditTrunkCurrent.StyledSettings + [TStyledSetting.FontColor];

  if not TryDimParse(EditCoreSize.Text, Core) or not TryDimParse(EditRowHeight.Text, RowH) then
  begin
    AddPlacementMsg('Core block size and row height must be valid numbers.', PalRed, True);
    Exit;
  end;
  if (Core <= 0) or (RowH <= 0) then
  begin
    AddPlacementMsg('Core block size and row height must be positive numbers.', PalRed, True);
    Exit;
  end;

  // Error 1: the row height must be a multiple of the core block.
  if not IsMultipleOf(RowH, Core) then
  begin
    EditRowHeight.StyledSettings := EditRowHeight.StyledSettings - [TStyledSetting.FontColor];
    EditRowHeight.TextSettings.FontColor := TAlphaColorRec.Red;
    AddPlacementMsg(Format('Row height must be a multiple of the core block size (row height %s is not a multiple of %s).',
      [DimToStr(RowH), DimToStr(Core)]), PalRed, True);
  end;

  // Die area dimensions must also tile the core grid.
  if TryDimParse(EditDieW.Text, DieW) and (DieW > 0) and
     (not IsMultipleOf(DieW, Core)) then
  begin
    EditDieW.StyledSettings := EditDieW.StyledSettings - [TStyledSetting.FontColor];
    EditDieW.TextSettings.FontColor := TAlphaColorRec.Red;
    AddPlacementMsg(Format('Die width must be a multiple of the core block size (die width %s is not a multiple of %s).',
      [DimToStr(DieW), DimToStr(Core)]), PalRed, True);
  end;
  if TryDimParse(EditDieH.Text, DieH) and (DieH > 0) and
     (not IsMultipleOf(DieH, Core)) then
  begin
    EditDieH.StyledSettings := EditDieH.StyledSettings - [TStyledSetting.FontColor];
    EditDieH.TextSettings.FontColor := TAlphaColorRec.Red;
    AddPlacementMsg(Format('Die height must be a multiple of the core block size (die height %s is not a multiple of %s).',
      [DimToStr(DieH), DimToStr(Core)]), PalRed, True);
  end;

  // Target utilization must stay within [0, 100]%.
  if TryDimParse(EditUtilization.Text, Util) and ((Util < 0) or (Util > 100)) then
  begin
    EditUtilization.StyledSettings := EditUtilization.StyledSettings - [TStyledSetting.FontColor];
    EditUtilization.TextSettings.FontColor := TAlphaColorRec.Red;
    AddPlacementMsg(Format('Target utilization must be between 0 and 100%% (value is %s).',
      [DimToStr(Util)]), PalRed, True);
  end;

  // Every remaining text box must contain a valid number.
  if not TryDimParse(EditDieW.Text, DieW) then
    AddPlacementMsg('Die width must be a valid number.', PalRed, True);
  if not TryDimParse(EditDieH.Text, DieH) then
    AddPlacementMsg('Die height must be a valid number.', PalRed, True);
  if not TryDimParse(EditUtilization.Text, Util) then
    AddPlacementMsg('Target utilization must be a valid number.', PalRed, True);
  if not TryDimParse(EditBiasCurrent.Text, Bias) then
    AddPlacementMsg('Max bias current must be a valid number.', PalRed, True);
  if not TryDimParse(EditTrunkCurrent.Text, Bias) then
    AddPlacementMsg('Max trunk current must be a valid number.', PalRed, True);
  // A trunk carries whole bias taps, so its limit can never be below the tap
  // limit: a lower value could not carry even one branch.
  TrunkUa := 0;
  if TryDimParse(EditBiasCurrent.Text, Bias) and
     TryDimParse(EditTrunkCurrent.Text, TrunkUa) and
     (Bias > 0) and (TrunkUa > 0) and (TrunkUa < Bias) then
  begin
    EditTrunkCurrent.StyledSettings := EditTrunkCurrent.StyledSettings - [TStyledSetting.FontColor];
    EditTrunkCurrent.TextSettings.FontColor := TAlphaColorRec.Red;
    AddPlacementMsg(Format('Max trunk current must be at least the max bias current (trunk %s uA is below the tap current %s uA).',
      [DimToStr(TrunkUa), DimToStr(Bias)]), PalRed, True);
  end;
  if not TryDimParse(EditPTLLength.Text, PTL) then
    AddPlacementMsg('Max PTL length must be a valid number.', PalRed, True);
  if not TryDimParse(EditFreqGHz.Text, Bias) then
    AddPlacementMsg('Operating frequency must be a valid number.', PalRed, True)
  else if Bias <= 0 then
    AddPlacementMsg('Operating frequency must be positive.', PalRed, True);
  if not TryDimParse(EditPTLDelay.Text, PTL) then
    AddPlacementMsg('PTL propagation delay must be a valid number.', PalRed, True)
  else if PTL <= 0 then
    AddPlacementMsg('PTL propagation delay must be positive.', PalRed, True);
  if not TryDimParse(EditPulseWidth.Text, PTL) then
    AddPlacementMsg('Pulse width must be a valid number.', PalRed, True)
  else if PTL <= 0 then
    AddPlacementMsg('Pulse width must be positive.', PalRed, True);

  // The bias-routing layer must be a valid selection from the library.
  if FBiasLayer = '' then
    AddPlacementMsg('Select a bias routing layer.', PalRed, True);

  // Which cells actually appear in the parsed netlist?
  UsedNames := nil;
  if FModel <> nil then
  begin
    UsedNames := TDictionary<string, Boolean>.Create;
    for Gate in FModel.Gates do
      if Gate.CellName <> '' then
        UsedNames.AddOrSetValue(Gate.CellName, True);
  end;
  ErrMsgs := TStringList.Create;
  WarnMsgs := TStringList.Create;
  try
    if FLib <> nil then
      for Cell in FLib.Cells do
      begin
        Used := (UsedNames <> nil) and UsedNames.ContainsKey(Cell.Name);

        // Width must tile the core grid: report each cell that fails.
        if (Cell.Width > 0) and (not IsMultipleOf(Cell.Width, Core)) then
        begin
          if Used then
            ErrMsgs.Add(Format('Cell "%s" width %s is not a multiple of the block and cell is used in the netlist.',
              [Cell.Name, DimToStr(Cell.Width)]))
          else
            WarnMsgs.Add(Format('Cell "%s" width %s is not a multiple of the block but cell isn''t used.',
              [Cell.Name, DimToStr(Cell.Width)]));
        end;

        CellH := Cell.Height;
        if CellH <= 0 then
          Continue;
        // A cell whose height does not match the configured row height
        // cannot be placed in a row and is excluded by the height check.
        if Abs(CellH - RowH) > 1e-6 then
        begin
          if Used then
            ErrMsgs.Add(Format('Cell "%s" will not fit in a row, and cell is used in the netlist.',
              [Cell.Name]))
          else
            WarnMsgs.Add(Format('Cell "%s" will not fit in a row, but is not used in this netlist.',
              [Cell.Name]));
        end;
      end;

    // Order: the row-multiple error was added first, then all other errors
    // (used in netlist), then all warnings (not used in netlist).
    for i := 0 to ErrMsgs.Count - 1 do
      AddPlacementMsg(ErrMsgs[i], PalRed, True);
    for i := 0 to WarnMsgs.Count - 1 do
      AddPlacementMsg(WarnMsgs[i], PalOrange, False);
  finally
    ErrMsgs.Free;
    WarnMsgs.Free;
    UsedNames.Free;
  end;
end;

procedure TForm1.AddPlacementMsg(const Text: string; Color: TAlphaColor;
  IsError: Boolean);
var
  Item: TListBoxItem;
begin
  Item := TListBoxItem.Create(ListBoxPlacementErrors);
  Item.Parent := ListBoxPlacementErrors;
  if IsError then
  begin
    Inc(FPlacementErrorCount);
    Item.Text := '[ERROR] ' + Text;
  end
  else
    Item.Text := '[WARNING] ' + Text;
  Item.StyledSettings := Item.StyledSettings - [TStyledSetting.FontColor];
  Item.TextSettings.FontColor := Color;
end;

procedure TForm1.EditPlacementChanged(Sender: TObject);
begin
  if FPlacementInitialized and (not FFormattingPlacement) then
  begin
    ValidatePlacement;
    UpdateUI;
  end;
end;

procedure TForm1.ComboBiasLayerChange(Sender: TObject);
begin
  if ComboBiasLayer.ItemIndex >= 0 then
    FBiasLayer := ComboBiasLayer.Items[ComboBiasLayer.ItemIndex]
  else
    FBiasLayer := '';
  if FPlacementInitialized and (not FFormattingPlacement) then
  begin
    ValidatePlacement;
    UpdateUI;
  end;
end;

// Fills the bias-routing-layer dropdown from the parsed library's layer stack,
// preserving the current selection if it is still present.
procedure TForm1.PopulateBiasLayerCombo;
var
  i: Integer;
  Sel: string;
begin
  if ComboBiasLayer = nil then
    Exit;
  Sel := FBiasLayer;
  ComboBiasLayer.Items.BeginUpdate;
  try
    ComboBiasLayer.Items.Clear;
    if FLib <> nil then
      for i := 0 to FLib.Layers.Count - 1 do
        ComboBiasLayer.Items.Add(FLib.Layers[i].Name);
  finally
    ComboBiasLayer.Items.EndUpdate;
  end;
  if Sel <> '' then
  begin
    i := ComboBiasLayer.Items.IndexOf(Sel);
    if i >= 0 then
      ComboBiasLayer.ItemIndex := i;
  end;
end;

procedure TForm1.EditPlacementKeyDown(Sender: TObject; var Key: Word;
  var KeyChar: WideChar; Shift: TShiftState);
begin
  if Key = vkReturn then
  begin
    Key := 0;
    if FPlacementInitialized then
    begin
      FormatPlacementFields;
      ValidatePlacement;
      UpdateUI;
    end;
  end;
end;

procedure TForm1.SaveProjectState;
begin
  if FProjectPath = '' then
  begin
    UpdateUI;
    Exit;
  end;
  // While a project is being opened, the form state is only partially
  // restored; do not let intermediate loader saves clobber the loaded data.
  if FLoadingProject then
  begin
    UpdateUI;
    Exit;
  end;
  FProject.LefFile := FLefFile;
  FProject.CellFolder := FCellFolder;
  FProject.BlifFile := FBlifFile;
  FProject.Splitters.Assign(FSplitterNames);
  FProject.Buffers.Assign(FBufferNames);
  if FFlipFlopNames.Count > 0 then
    FProject.FlipFlop := FFlipFlopNames[0]
  else
    FProject.FlipFlop := '';
  FProject.SplittersInserted := (FFlowStage >= fsSplitters);
  FProject.ClockSeedBuffers := CheckBoxSeedBuffers.IsChecked;
  FProject.LastTab := TabControl1.TabIndex;
  FProject.SliderPos := FSliderPos;
  // Placement configuration: store the raw text so even invalid entries
  // (and their error states) are preserved across sessions.
  FProject.CoreSize := EditCoreSize.Text;
  FProject.RowHeight := EditRowHeight.Text;
  FProject.DieW := EditDieW.Text;
  FProject.DieH := EditDieH.Text;
  FProject.Utilization := EditUtilization.Text;
  FProject.BiasCurrent := EditBiasCurrent.Text;
  FProject.TrunkCurrent := EditTrunkCurrent.Text;
  FProject.PTLLength := EditPTLLength.Text;
  FProject.FreqGHz := EditFreqGHz.Text;
  FProject.PTLDelay := EditPTLDelay.Text;
  FProject.PulseWidth := EditPulseWidth.Text;
  FProject.BiasLayer := FBiasLayer;
  try
    FProject.SaveToFile(FProjectPath);
  except
    on E: Exception do
      ShowMessage('Failed to save project:' + sLineBreak + E.Message);
  end;
  if FRecent.IndexOf(FProjectPath) < 0 then
  begin
    FRecent.Insert(0, FProjectPath);
    while FRecent.Count > MaxRecentProjects do
      FRecent.Delete(FRecent.Count - 1);
    // Best-effort: the recent-projects file is optional state (see above).
    try
      SaveRecentProjects(FProjectPath, FRecent);
    except
    end;
    UpdateRecentList;
  end;
  UpdateUI;
end;

procedure TForm1.SaveProjectFileAs;
begin
  // Start at the current project when there is one, so Save As defaults to a
  // neighbouring name; otherwise fall back to the BLIF folder.
  if FProjectPath <> '' then
  begin
    SaveDialog1.InitialDir := ExtractFilePath(FProjectPath);
    SaveDialog1.FileName := ExtractFileName(FProjectPath);
  end
  else
  begin
    if FBlifFile <> '' then
      SaveDialog1.InitialDir := ExtractFilePath(FBlifFile);
    SaveDialog1.FileName := 'Project';
  end;
  if not SaveDialog1.Execute then
    Exit;
  FProjectPath := SaveDialog1.FileName;
  SaveProjectState;
end;

procedure TForm1.ApplyProjectSettings;
var
  i: Integer;
begin
  if FProject.LefFile <> '' then
    LoadLibraryFromFile(FProject.LefFile, False);
  if FProject.CellFolder <> '' then
    SetCellFolderPath(FProject.CellFolder, False);
  if (FLib <> nil) and (FProject.BlifFile <> '') then
    LoadNetlistFromFile(FProject.BlifFile, False);

  // Restore component selections (valid even if some files failed to load).
  FSplitterNames.Assign(FProject.Splitters);
  FFlipFlopNames.Clear;
  if FProject.FlipFlop <> '' then
    FFlipFlopNames.Add(FProject.FlipFlop);
  FBufferNames.Assign(FProject.Buffers);

  // Restore the pipeline slider so the DFF-insertion mode (compact vs
  // delay-levelized) matches what the user chose.
  FSliderPos := FProject.SliderPos;
  if FSliderPos < 0 then
    FSliderPos := 0;
  if FSliderPos > 100 then
    FSliderPos := 100;
  CheckBoxSeedBuffers.IsChecked := FProject.ClockSeedBuffers;

  // Restore the placement config verbatim (raw text, so invalid entries and their
  // errors return too); marking it initialized stops the derivation from overwriting.
  if FProject.CoreSize <> '' then
  begin
    EditCoreSize.Text := FProject.CoreSize;
    EditRowHeight.Text := FProject.RowHeight;
    EditDieW.Text := FProject.DieW;
    EditDieH.Text := FProject.DieH;
    EditUtilization.Text := FProject.Utilization;
    EditBiasCurrent.Text := FProject.BiasCurrent;
    EditTrunkCurrent.Text := FProject.TrunkCurrent;
    EditPTLLength.Text := FProject.PTLLength;
    EditFreqGHz.Text := FProject.FreqGHz;
    EditPTLDelay.Text := FProject.PTLDelay;
    EditPulseWidth.Text := FProject.PulseWidth;
    // Older projects have no frequency/delay/pulse fields; give them defaults
    // so the new fields validate instead of appearing empty.
    if EditFreqGHz.Text = '' then
      EditFreqGHz.Text := '10';
    if EditPTLDelay.Text = '' then
      EditPTLDelay.Text := '10';
    if EditPulseWidth.Text = '' then
      EditPulseWidth.Text := '5';
    FBiasLayer := FProject.BiasLayer;
    if ComboBiasLayer <> nil then
    begin
      i := ComboBiasLayer.Items.IndexOf(FBiasLayer);
      if i >= 0 then
        ComboBiasLayer.ItemIndex := i
      else
        ComboBiasLayer.ItemIndex := 0;
    end;
    // Keep the flag so entering the page validates the restored values instead
    // of deriving defaults over them. Nothing else is done here: formatting and
    // validation belong to the placement page, not to loading.
    FPlacementInitialized := True;
  end;

  // Reproduce the splitter-inserted netlist if the project had reached it.
  if (FModel <> nil) and FProject.SplittersInserted then
  begin
    RunSplitterInsertion;
    if FFlowStage < fsSplitters then FFlowStage := fsSplitters;
  end;
end;

procedure TForm1.OpenProjectFile(const Path: string);
begin
  if not TFile.Exists(Path) then
  begin
    ShowMessage('Project file not found:' + sLineBreak + Path);
    RemoveRecentProject(Path);
    Exit;
  end;
  try
    FProject.LoadFromFile(Path);
  except
    on E: Exception do
    begin
      ShowMessage('Failed to read project:' + sLineBreak + E.Message);
      Exit;
    end;
  end;
  FProjectPath := Path;
  FLoadingProject := True;
  try
    ResetWorkspace;
    ApplyProjectSettings;
  finally
    FLoadingProject := False;
  end;
  UpdateRecentList;
  if FProject.LastTab < 0 then
    FProject.LastTab := 0;
  if FProject.LastTab > TabControl1.TabCount - 1 then
    FProject.LastTab := TabControl1.TabCount - 1;
  // Everything from the floorplan onwards is derived, and it is not
  // deterministic: the user may have placed/optimised several times since the
  // save, and we only store the config. Restoring past it would rebuild a
  // different layout (and blank the page while it does), so cap the restore at
  // the configuration page and let the user re-run from there.
  if FProject.LastTab > TabPlacement then
    FProject.LastTab := TabPlacement;
  if FModel <> nil then
    TabControl1.TabIndex := FProject.LastTab
  else if FLib <> nil then
    TabControl1.TabIndex := TabLibrary
  else
    TabControl1.TabIndex := TabStart;
  UpdateUI;
  SaveProjectState;
end;

procedure TForm1.ButtonNewProjectClick(Sender: TObject);
begin
  ResetWorkspace;
  FProjectPath := '';
  FProject.Clear;
  UpdateUI;
  TabControl1.TabIndex := TabLibrary;
end;

procedure TForm1.ButtonOpenProjectClick(Sender: TObject);
begin
  OpenDialog1.Filter := 'FluxRoute projects (*.fluxroute)|*.fluxroute|All files (*.*)|*.*';
  OpenDialog1.FilterIndex := 1;
  if not OpenDialog1.Execute then
    Exit;
  OpenProjectFile(OpenDialog1.FileName);
end;

procedure TForm1.ListBoxRecentDblClick(Sender: TObject);
var
  Item: TListBoxItem;
begin
  if ListBoxRecent.ItemIndex < 0 then
    Exit;
  Item := ListBoxRecent.ItemByIndex(ListBoxRecent.ItemIndex);
  if Item = nil then
    Exit;
  OpenProjectFile(Item.Text);
end;
