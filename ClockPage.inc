// Clock page: the clock model build, the network painter and page repaint.
// Included from MainWindow's implementation via {$I ClockPage.inc}.

procedure TForm1.RepaintClockPage;
begin
  if TabControl1.TabIndex <> TabClock then
    Exit;
  // Repaint the tab control and buttons to ensure everything is refreshed
  TabControl1.Repaint;
  ButtonBack.Repaint;
  ButtonNext.Repaint;
end;

procedure TForm1.FreeClockModel;
begin
  FClockNet.Free;
  FClockNet := nil;
  FClockBufferedModel.Free;
  FClockBufferedModel := nil;
  FClockModel.Free;
  FClockModel := nil;
end;

procedure TForm1.BuildClockModel;
var
  Types: TArray<TSplitterType>;
  BufTypes: TArray<TBufferType>;
  Errors: TStringList;
  i, n, BufN: Integer;
  Cell: TCell;
  Delay: Double;
  NumOutputs: Integer;
  InPin, OutPin: string;
begin
  FreeClockModel;
  if (FPipelineModel = nil) or (FLib = nil) or (FFlipFlopNames.Count = 0) then
    Exit;

  // Work on a deep copy: the pipeline view keeps showing the pure DFF view.
  FClockModel := FPipelineModel.Clone;

  // Every splitter candidate in the library (generic sizes), with timing.
  n := 0;
  SetLength(Types, FLib.Cells.Count);
  for i := 0 to FLib.Cells.Count - 1 do
  begin
    Cell := FLib.Cells[i];
    if not IsSplitterCandidate(Cell, NumOutputs) then
      Continue;
    Delay := CellDelayPs(Cell);
    if Delay < 0 then
      Continue;
    Types[n].CellName := Cell.Name;
    Types[n].OutputCount := NumOutputs;
    Types[n].DelayPs := Delay;
    Inc(n);
  end;
  SetLength(Types, n);

  // The selected buffer cells, with timing, for tree balancing.
  BufN := 0;
  SetLength(BufTypes, FBufferNames.Count);
  for i := 0 to FBufferNames.Count - 1 do
  begin
    Cell := FLib.FindCell(FBufferNames[i]);
    if (Cell = nil) or not IsBufferCandidate(Cell, InPin, OutPin) then
      Continue;
    Delay := CellDelayPs(Cell);
    if Delay < 0 then
      Continue;
    BufTypes[BufN].CellName := Cell.Name;
    BufTypes[BufN].DelayPs := Delay;
    BufTypes[BufN].InputPin := InPin;
    BufTypes[BufN].OutputPin := OutPin;
    Inc(BufN);
  end;
  SetLength(BufTypes, BufN);

  Errors := TStringList.Create;
  try
    FClockNet := BuildClockNetwork(FClockModel, FLib, Types, BufTypes, Errors);
    // Keep the original clock network (with its synthetic delay blocks) intact
    // for the clock view; build a separate copy with the delay blocks replaced
    // by real buffer chains, to be used by the clock placement later.
    if FClockNet <> nil then
    begin
      FClockBufferedModel := FClockModel.Clone;
      ReplaceClockDelaysWithBuffers(FClockBufferedModel, FLib, BufTypes, Errors);
    end;
    memoNetlist.Lines.AddStrings(Errors); // diagnostics incl. per-stage seeds
  finally
    Errors.Free;
  end;
end;

// One node of a row's clock distribution tree: either a splitter (interior)
// or a terminating clocked component (leaf). Built fresh per paint.
type
  TClockTreeNode = class
  public
    Gate: TGateInstance;
    IsLeaf: Boolean;
    Depth: Integer;
    X, Y: Single;
    Children: TObjectList<TClockTreeNode>;
    constructor Create(AGate: TGateInstance; AIsLeaf: Boolean; ADepth: Integer);
    destructor Destroy; override;
  end;

constructor TClockTreeNode.Create(AGate: TGateInstance; AIsLeaf: Boolean;
  ADepth: Integer);
begin
  Gate := AGate;
  IsLeaf := AIsLeaf;
  Depth := ADepth;
  Children := TObjectList<TClockTreeNode>.Create(True);
end;

destructor TClockTreeNode.Destroy;
begin
  Children.Free;
  inherited;
end;

procedure TForm1.PaintClockNetwork(Sender: TObject; Canvas: TCanvas);
var
  Visited: TDictionary<TGateInstance, Boolean>;

  // Builds one row's distribution tree from its tap net. Interior nodes are
  // splitters; leaves are terminating clocked components (drawn without any
  // of their own children).
  procedure BuildTree(const ANetName: string; Depth: Integer;
    Parent: TClockTreeNode; var MaxDepth: Integer);
  var
    Net: TNet;
    NC: TNetConnection;
    OutConn: TPinConnection;
    Node: TClockTreeNode;
  begin
    // The spine's delay/buffer chain (clk_delay_*) belongs to no row tree.
    if (Length(ANetName) >= Length(UNetNaming.ClockDelayPrefix)) and
       SameText(Copy(ANetName, 1, Length(UNetNaming.ClockDelayPrefix)), UNetNaming.ClockDelayPrefix) then
      Exit;
    if not FClockModel.Nets.TryGetValue(ANetName, Net) then
      Exit;
    for NC in Net.Connections do
    begin
      if NC.IsDriver then
        Continue;
      if Visited.ContainsKey(NC.Gate) then
        Continue;
      Visited.Add(NC.Gate, True);
      if IsClockDelayGate(NC.Gate) then
        Continue; // spine element, not part of this row's tree
      Node := TClockTreeNode.Create(NC.Gate, CellHasClock(NC.Gate.Cell),
        Depth);
      if Node.Depth > MaxDepth then
        MaxDepth := Node.Depth;
      Parent.Children.Add(Node);
      if not Node.IsLeaf then
        for OutConn in NC.Gate.Connections do
          if OutConn.Port.Direction = pdOutput then
            BuildTree(OutConn.NetName, Depth + 1, Node, MaxDepth);
    end;
  end;

  function CountLeaves(Node: TClockTreeNode): Integer;
  var
    i: Integer;
  begin
    if Node.Children.Count = 0 then
      Result := 1
    else
    begin
      Result := 0;
      for i := 0 to Node.Children.Count - 1 do
        Result := Result + CountLeaves(Node.Children[i]);
    end;
  end;

var
  R: TRectF;
  rIdx, MaxDepth, i: Integer;
  TrunkX, TreeX0, ColGap, LayerStep, Sq, RootY, YMid, StageDelay: Single;
  TapNetName, DelayTxt, LevelTxt: string;
  Roots: TObjectList<TClockTreeNode>;
  RootYs: TArray<Single>;
  RowHeights: TArray<Single>;
  MaxDepths: TArray<Integer>;
  Node, TrunkNode: TClockTreeNode;
  ClipState: TCanvasSaveState;
  LevelCols: TList<Integer>;
  ClkY: Single;
  ClkLbl: string;

  // World -> screen transforms (pan + zoom), mirroring PaintPipeline.
  // Declared before the draw helpers so they can reference them.
  function WX(AValue: Single): Single;
  begin
    Result := FClockPanX + AValue * FClockZoom;
  end;

  function WY(AValue: Single): Single;
  begin
    Result := FClockPanY + AValue * FClockZoom;
  end;

  function WLen(AValue: Single): Single;
  begin
    Result := AValue * FClockZoom;
  end;

  // Left-aligned tree layout (like DFSLayout): a child sits above its parent or
  // up-and-right, never left; later siblings take the next free columns right.
  procedure LayoutSubtree(Node: TClockTreeNode; Depth: Integer;
    BaseCol: Integer; BaseY: Single);
  var
    i: Integer;
    ParentCol: Integer;
  begin
    Node.Y := BaseY - Node.Depth * LayerStep;

    // Ensure we have a column counter for this depth
    while LevelCols.Count <= Depth do
      LevelCols.Add(0);

    // Never left of the parent, never left of an earlier sibling subtree.
    if LevelCols[Depth] < BaseCol then
      LevelCols[Depth] := BaseCol;
    ParentCol := LevelCols[Depth];

    // Position this node
    Node.X := TreeX0 + ParentCol * ColGap;

    // Reserve next column for this depth
    LevelCols[Depth] := ParentCol + 1;

    // Lay out children recursively, floored at this node's column
    for i := 0 to Node.Children.Count - 1 do
      LayoutSubtree(Node.Children[i], Depth + 1, ParentCol, BaseY);

    // After laying out children, ensure the next node at this depth is at
    // least as far right as the rightmost child
    if Depth + 1 < LevelCols.Count then
      if LevelCols[Depth] < LevelCols[Depth + 1] then
        LevelCols[Depth] := LevelCols[Depth + 1];
  end;

  // Filled-segment connector: bypasses stroke rendering entirely (fills
  // demonstrably render in this view). Handles vertical, horizontal and
  // diagonal hops.
  procedure DrawSeg(X1, Y1, X2, Y2: Single);
  begin
    Canvas.DrawLine(TPointF.Create(WX(X1), WY(Y1)),
      TPointF.Create(WX(X2), WY(Y2)), 1.0);
  end;

  // Returns this gate's clock input pin name using the configured clock
  // prefixes (same generic resolution the DFF insertion relies on).
  function ClockPinNameOf(Gate: TGateInstance): string;
  var
    P: TPort;
  begin
    Result := UNetNaming.ClockRootName;
    if Gate = nil then
      Exit;
    for P in Gate.Cell.Ports do
      if (P.Direction = pdInput) and IsClockPinName(P.Name) then
        Exit(P.Name);
  end;

  // Thin connector lines: parent centre -> child centre.
  procedure DrawEdges(Node: TClockTreeNode);
  var
    i: Integer;
  begin
    for i := 0 to Node.Children.Count - 1 do
    begin
      DrawSeg(Node.X, Node.Y,
        Node.Children[i].X, Node.Children[i].Y);
      DrawEdges(Node.Children[i]);
    end;
  end;

  procedure DrawNodes(Node: TClockTreeNode);
  var
    i: Integer;
    Clr: TAlphaColor;
    NumOutputs: Integer;
  begin
    if Node.IsLeaf then
    begin
      if FSplitterNames.IndexOf(Node.Gate.Cell.Name) >= 0 then
        Clr := PalGreen
      else if FFlipFlopNames.IndexOf(Node.Gate.Cell.Name) >= 0 then
        Clr := PalRedDeep
      else
        Clr := PalBlueDark;
      Canvas.Fill.Color := Clr;
      Canvas.FillRect(TRectF.Create(
        WX(Node.X) - WLen(Sq) / 2, WY(Node.Y) - WLen(Sq) / 2,
        WX(Node.X) + WLen(Sq) / 2, WY(Node.Y) + WLen(Sq) / 2), 0, 0, [], 1.0);
    end
    else
    begin
      // Interior tree node. Splitters stay green (the exception); buffers
      // and any other unclocked cell use the light-blue general colour.
      if IsSplitterCandidate(Node.Gate.Cell, NumOutputs) then
        Canvas.Fill.Color := PalGreen
      else
        Canvas.Fill.Color := PalBlueLight;
      Canvas.FillRect(TRectF.Create(
        WX(Node.X) - WLen(Sq) / 2, WY(Node.Y) - WLen(Sq) / 2,
        WX(Node.X) + WLen(Sq) / 2, WY(Node.Y) + WLen(Sq) / 2), 0, 0, [], 1.0);
    end;
    for i := 0 to Node.Children.Count - 1 do
      DrawNodes(Node.Children[i]);
  end;

begin
  R := TRectF.Create(0, 0, PaintBox2.Width, PaintBox2.Height);
  Canvas.Fill.Color := TAlphaColorRec.White;
  Canvas.FillRect(R, 0, 0, [], 1.0);

  // Mask everything outside the paint box. The D2D canvas only honors
  // IntersectClipRect while a save state is active - without this the
  // drawing bleeds over the Back/Next buttons.
  ClipState := Canvas.SaveState;
  try
    Canvas.IntersectClipRect(R);

    if (FClockModel = nil) or (FClockNet = nil) then
    begin
      Canvas.Fill.Color := TAlphaColorRec.Dimgray;
      Canvas.FillText(R, 'No clock network built - complete the previous steps.',
        False, 1.0, [], TTextAlign.Center, TTextAlign.Center);
      Exit;
    end;

    Roots := TObjectList<TClockTreeNode>.Create(True);
    Visited := TDictionary<TGateInstance, Boolean>.Create;
    try
    // Build one tree per row; row 0 is the highest clock level (the clock
    // source end of the counter-flow spine, drawn at the bottom).
    SetLength(RootYs, FClockNet.Rows.Count);
    SetLength(RowHeights, FClockNet.Rows.Count);
    SetLength(MaxDepths, FClockNet.Rows.Count);
    for rIdx := 0 to FClockNet.Rows.Count - 1 do
    begin
      if rIdx = 0 then
        TapNetName := FClockNet.SourceNet // spine_0 == clk: source junction
      else if rIdx <= FClockNet.Rows.Count - 2 then
        TapNetName := UNetNaming.ClockSpineNetName(rIdx) // feeds junction S<rIdx>
      else
        // Topmost band (level 1): fed directly by the final delay - no
        // junction exists here, so walk the row net itself.
        TapNetName := UNetNaming.ClockRowNetName(FClockNet.Rows[rIdx]);
      Node := TClockTreeNode.Create(nil, False, 0); // virtual root
      Roots.Add(Node);
      MaxDepth := 0;
      BuildTree(TapNetName, 0, Node, MaxDepth);
      MaxDepths[rIdx] := MaxDepth;
      RootYs[rIdx] := -1;
    end;

    Canvas.Stroke.Kind := TBrushKind.Solid;
    Canvas.Stroke.Color := PalGreyGrid;
    Canvas.Stroke.Thickness := 1.6;

    TrunkX := 110;
    TreeX0 := 210;
    Sq := 26;
    ColGap := 64;
    LayerStep := 44;

    // Assign trunk Y positions, bottom (row 0) upward. Each row claims
    // vertical space for its deepest tree level plus a gap for the delay
    // block between rows. Leave room at the very bottom for the clk input.
    RootY := PaintBox2.Height - 110;
    for rIdx := 0 to Roots.Count - 1 do
    begin
      RootYs[rIdx] := RootY;
      RowHeights[rIdx] := (MaxDepths[rIdx] + 1) * LayerStep + 34;
      RootY := RootY - RowHeights[rIdx];
    end;

    // Layout + draw each row's tree: the root splitter is pinned to the
    // trunk; its children fan upward, siblings branching right.
    LevelCols := TList<Integer>.Create;
    try
      for rIdx := 0 to Roots.Count - 1 do
      begin
        Node := Roots[rIdx];
        if Node.Children.Count > 0 then
        begin
          // The trunk (junction splitter) is tagged; everything else is
          // subtree and must sprout to the right of the trunk.
          TrunkNode := nil;
          for i := 0 to Node.Children.Count - 1 do
            if (Node.Children[i].Gate <> nil) and
               Node.Children[i].Gate.ClockTrunk then
            begin
              TrunkNode := Node.Children[i];
              Break;
            end;

          LevelCols.Clear;
          if TrunkNode <> nil then
          begin
            // Pin the trunk junction on the spine; its children (this row's
            // distribution tree) grow right from the first subtree column.
            TrunkNode.X := TrunkX;
            TrunkNode.Y := RootYs[rIdx];
            TrunkNode.Depth := 0;
            for i := 0 to TrunkNode.Children.Count - 1 do
              LayoutSubtree(TrunkNode.Children[i], 1, 0, RootYs[rIdx]);
            DrawEdges(TrunkNode);
            DrawNodes(TrunkNode);
          end
          else
          begin
            // No junction on this row (the topmost band): the whole tree is
            // subtree, so it sprouts right of the trunk from column 0.
            for i := 0 to Node.Children.Count - 1 do
            begin
              LayoutSubtree(Node.Children[i], 0, 0, RootYs[rIdx]);
              DrawEdges(Node.Children[i]);
              DrawNodes(Node.Children[i]);
            end;
          end;
        end;
      end;
    finally
      LevelCols.Free;
    end;

    // Trunk: splitter -> delay -> splitter ... straight up the left edge.
    for rIdx := 0 to Roots.Count - 2 do
    begin
      if (Roots[rIdx].Children.Count = 0) or
         (Roots[rIdx + 1].Children.Count = 0) then
        Continue;
      YMid := (RootYs[rIdx] + RootYs[rIdx + 1]) / 2;
      // vertical trunk segments into and out of the delay block
      DrawSeg(TrunkX, RootYs[rIdx], TrunkX, YMid - 15);
      DrawSeg(TrunkX, YMid + 15, TrunkX, RootYs[rIdx + 1]);

      StageDelay := FClockNet.Stages[rIdx].DelayPs;
      DelayTxt := Format('%.1f ps', [StageDelay]);

      Canvas.Fill.Color := TAlphaColorRec.Black;
      Canvas.FillRect(TRectF.Create(WX(TrunkX) - WLen(46), WY(YMid) - WLen(15),
        WX(TrunkX) + WLen(46), WY(YMid) + WLen(15)), 0, 0, [], 1.0);
      Canvas.Fill.Color := TAlphaColorRec.White;
      Canvas.FillText(TRectF.Create(WX(TrunkX) - WLen(46), WY(YMid) - WLen(15),
        WX(TrunkX) + WLen(46), WY(YMid) + WLen(15)), DelayTxt, False, 1.0,
        [], TTextAlign.Center, TTextAlign.Center);
    end;

    // Final (topmost) band has no junction splitter, so the trunk's wire
    // taps horizontally into that row's tree to the right.
    if Roots.Count > 0 then
    begin
      Node := Roots[Roots.Count - 1];
      for i := 0 to Node.Children.Count - 1 do
        if Node.Children[i].X > TrunkX then
          DrawSeg(TrunkX, Node.Children[i].Y, Node.Children[i].X, Node.Children[i].Y);
    end;

    // Layer labels: to the LEFT of each row's junction splitter.
    for rIdx := 0 to Roots.Count - 1 do
    begin
      LevelTxt := Format('L%d', [FClockNet.Rows[rIdx]]);
      Canvas.Fill.Color := TAlphaColorRec.Dimgray;
      Canvas.FillText(TRectF.Create(
        WX(TrunkX) - WLen(Sq) / 2 - WLen(56), WY(RootYs[rIdx]) - WLen(11),
        WX(TrunkX) - WLen(Sq) / 2 - WLen(4), WY(RootYs[rIdx]) + WLen(11)),
        LevelTxt, False, 1.0, [], TTextAlign.Trailing, TTextAlign.Center);
    end;

    // Clock input: a primary-input square (same yellow as other inputs)
    // feeding the first splitter from below. Labelled with the clock pin
    // name resolved via the configured clock prefixes.
    ClkY := PaintBox2.Height - 45;
    DrawSeg(TrunkX, ClkY - Sq / 2, TrunkX, RootYs[0] + Sq / 2);
    Canvas.Fill.Color := PalYellow;
    Canvas.FillRect(TRectF.Create(WX(TrunkX) - WLen(Sq) / 2,
      WY(ClkY) - WLen(Sq) / 2, WX(TrunkX) + WLen(Sq) / 2,
      WY(ClkY) + WLen(Sq) / 2), 0, 0, [], 1.0);

    ClkLbl := ClockNetFor(FClockModel);
    if (Roots[0].Children.Count > 0) and
       (Roots[0].Children[0].Gate <> nil) then
      ClkLbl := ClockPinNameOf(Roots[0].Children[0].Gate);
    Canvas.Fill.Color := TAlphaColorRec.Dimgray;
    Canvas.FillText(TRectF.Create(WX(TrunkX) - WLen(40),
      WY(ClkY) + WLen(Sq) / 2, WX(TrunkX) + WLen(40),
      WY(ClkY) + WLen(Sq) / 2 + WLen(16)), ClkLbl, False, 1.0, [],
      TTextAlign.Center, TTextAlign.Center);
  finally
    Roots.Free;
    Visited.Free;
  end;
  finally
    Canvas.RestoreState(ClipState);
  end;
end;
