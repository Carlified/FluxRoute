// Navigation captions and the per-page help button.

// Short page name for the Back/Next buttons (tab captions are longer).
function TabShortName(Index: Integer): string;
begin
  case Index of
    TabStart:      Result := 'Start';
    TabLibrary:    Result := 'Library';
    TabComponents: Result := 'Components';
    TabNetlist:    Result := 'BLIF';
    TabPipeline:   Result := 'Pipeline';
    TabClock:      Result := 'Clock';
    TabPlacement:  Result := 'Placement';
    TabFloorplan:  Result := 'Floorplan';
    TabRouting:    Result := 'Routing';
    TabExport:     Result := 'Export';
  else
    Result := 'Page ' + IntToStr(Index + 1);
  end;
end;

// Full page name, used as the help dialog heading.
function PageTitleForTab(Index: Integer): string;
begin
  case Index of
    TabStart:      Result := 'Start';
    TabLibrary:    Result := 'Library';
    TabComponents: Result := 'Components';
    TabNetlist:    Result := 'Netlist';
    TabPipeline:   Result := 'Pipeline view';
    TabClock:      Result := 'Clock network';
    TabPlacement:  Result := 'Placement configuration';
    TabFloorplan:  Result := 'Floorplan';
    TabRouting:    Result := 'Routing';
    TabExport:     Result := 'Export';
  else
    Result := 'Page ' + IntToStr(Index + 1);
  end;
end;

// Help text for a page. Shown under the page title in the Help dialog.
function HelpTextForTab(Index: Integer): string;
begin
  case Index of
    TabStart:
      Result :=
        'Start a new project or reopen one you were working on.' + sLineBreak +
        sLineBreak +
        '- New Project: begin from scratch. You will be asked for a LEF file next.' + sLineBreak +
        '- Open Project...: load a .fluxroute file and continue where you left off.' + sLineBreak +
        '- Recent projects: double-click an entry to reopen it.' + sLineBreak +
        sLineBreak +
        'Work is saved automatically. Ctrl+S (Cmd+S) saves in place; ' +
        'Ctrl+Shift+S (Cmd+Shift+S) saves a copy under a new name.';

    TabLibrary:
      Result :=
        'Point the flow at the cell library.' + sLineBreak +
        sLineBreak +
        '- Load LEF file: cell footprints plus the metal layer stack. ' +
        'The cells and the layer table are listed below.' + sLineBreak +
        '- Load Library: the folder holding the Verilog and SPICE sources for ' +
        'the cells. Sources are matched to cells by name.' + sLineBreak +
        sLineBreak +
        'Double-click a cell to inspect its timing. ' +
        'Both steps are needed before you can continue.';

    TabComponents:
      Result :=
        'Choose which library cells the flow may use.' + sLineBreak +
        sLineBreak +
        '- Splitters: copy one pulse to several outputs. At least one 1-to-2 ' +
        'splitter is required; nets with more than one load are split ' +
        'automatically.' + sLineBreak +
        '- DFF: the flip-flop used to re-clock signals in the pipeline.' + sLineBreak +
        '- Buffers: cells used to repair clock timing and long interconnect.' + sLineBreak +
        sLineBreak +
        'Double-click a library cell to add it; double-click a selected cell ' +
        'to remove it.';

    TabNetlist:
      Result :=
        'Load the circuit to place and route.' + sLineBreak +
        sLineBreak +
        '- Load BLIF file: the netlist. After loading, connectivity is checked ' +
        'and the clock levels are worked out.' + sLineBreak +
        sLineBreak +
        'Moving on from this page inserts splitters on every net with more than ' +
        'one load, so the rest of the flow works on a legal fan-out.';

    TabPipeline:
      Result :=
        'Decide how much pipelining the circuit gets.' + sLineBreak +
        sLineBreak +
        'The slider runs from Most compact to Highest frequency. Moving it ' +
        'right adds flip-flop stages, which shortens the longest combinational ' +
        'path and raises the clock rate at the cost of latency and area.' + sLineBreak +
        sLineBreak +
        'The figures at either end show the resulting clock frequency.';

    TabClock:
      Result :=
        'Builds the clock distribution tree.' + sLineBreak +
        sLineBreak +
        'Every clock level gets a row tree fed from a trunk that runs down the ' +
        'clock column from the clock pad.' + sLineBreak +
        sLineBreak +
        '- Seed stage buffers: when on, each stage delay is materialised as real ' +
        'buffer cells before the tree is balanced. Turn it off to keep the stage ' +
        'delays implicit and let validation add buffers only where needed.' + sLineBreak +
        sLineBreak +
        'Clock arrival and data arrival are compared after routing; a register ' +
        'whose data would arrive late gets buffers inserted on its trunk segment.';

    TabPlacement:
      Result :=
        'Parameters used to turn the circuit into a floorplan.' + sLineBreak +
        sLineBreak +
        '- Core block size, row height: size of the logic core and of one cell ' +
        'row, in um.' + sLineBreak +
        '- Die area: die width and height in um; the circuit must fit inside.' + sLineBreak +
        '- Utilisation: target fraction of each row filled by cells.' + sLineBreak +
        '- Bias current, bias layer, trunk current: how the bias supply is split ' +
        'into tracks, on which metal layer, and the current in the main trunk. ' +
        'The trunk carries whole taps, so its current must be at least the bias ' +
        'tap current.' + sLineBreak +
        '- Frequency: target clock frequency, used to budget interconnect delay.' + sLineBreak +
        '- PTL length, PTL delay: modelled passive transmission line length, and ' +
        'its delay per um.' + sLineBreak +
        '- Pulse width: width of one flux quantum pulse, used when sizing delays.' + sLineBreak +
        sLineBreak +
        'Problems are reported underneath and must be cleared before you can continue.';

    TabFloorplan:
      Result :=
        'Shows the placed circuit: rows of cells, the clock column and the bias trunk.' + sLineBreak +
        sLineBreak +
        '- Optimize Placement: re-pack the cells within their rows to shorten wiring.' + sLineBreak +
        '- Expand Bias Lines: grow the bias distribution to match the current ' +
        'settings. This has to be run once before routing. When the bias trunk ' +
        'or a clock lane needs more columns the die widens automatically for this ' +
        'run (up to a fixed multiple of its configured width) while the configured ' +
        'width is left untouched, so a reload reproduces the same layout. The die ' +
        'is never made taller: vertical space has to come from the configuration.' + sLineBreak +
        sLineBreak +
        'The check boxes toggle the overlays: cell names, logic connections, ' +
        'clock connections, the floorplan grid and the cells themselves.';

    TabRouting:
      Result :=
        'Route every net, then verify the result.' + sLineBreak +
        sLineBreak +
        '- Route and Validate: build the floorplan, route the signal nets layer ' +
        'by layer, route the bias lines, then validate. Nets that do not ' +
        'complete on one layer are retried on the next, then with vias; ' +
        'validation checks trace length against the delay budget and clock ' +
        'arrival against data arrival, repairing violations by inserting buffer ' +
        'cells until it is clean.' + sLineBreak +
        sLineBreak +
        'Routing stays locked once it has run until validation completes, so a ' +
        'routed circuit is always a verified one.';

    TabExport:
      Result :=
        'Write the layout and simulation files.' + sLineBreak +
        sLineBreak +
        '- Library folder: the block decks used by the exported netlist. ' +
        'Defaults to ./blocklib.' + sLineBreak +
        '- Output folder and name: the name is shared by every output file, so ' +
        'naming it "netlist" writes netlist.gds, netlist.cir, netlist.tb.json ' +
        'and netlist.metrics.json.' + sLineBreak +
        '- Export .gds: the layout. Export .cir: the JoSIM deck. ' +
        'Export .stats: design statistics (junction count, area and packing, ' +
        'wirelength, timing, routing runtime). (.def is not implemented yet.)' + sLineBreak +
        '- Recheck: re-run the preflight, which checks that every placed cell has ' +
        'a library source and a block deck.' + sLineBreak +
        '- Export: write the selected files.' + sLineBreak +
        sLineBreak +
        'The .tb.json testbench description is written alongside them and is used ' +
        'by the scripts in tools/.';

  else
    Result := '';
  end;
end;

// Hides a nav button without removing it from the layout: toggling Visible on
// Align = Right buttons makes FMX reassign the right-aligned slots, which swaps
// the two buttons. Opacity keeps the slots fixed and HitTest = False makes the
// hidden button unclickable.
procedure ShowNavButton(AButton: TButton; AShown: Boolean);
begin
  AButton.Visible := True;
  if AShown then
  begin
    AButton.Opacity := 1.0;
    AButton.HitTest := True;
  end
  else
  begin
    AButton.Opacity := 0.0;
    AButton.HitTest := False;
  end;
end;

procedure TForm1.UpdateNavButtons;
var
  Idx: Integer;
begin
  Idx := TabControl1.TabIndex;
  // The Start page is a gate: no Back/Next, so the only way out is loading a
  // project or starting a new one. The Library page also hides Back so the
  // user can never return to Start to pick a different project. The final
  // (Export) page hides Next for the same reason.
  ShowNavButton(ButtonBack, Idx > TabLibrary);
  ShowNavButton(ButtonNext, (Idx <> TabStart) and (Idx < TabControl1.TabCount - 1));
  if Idx > TabStart then
    ButtonBack.Text := '< ' + TabShortName(Idx - 1)
  else
    ButtonBack.Text := 'Back';
  if Idx < TabControl1.TabCount - 1 then
    ButtonNext.Text := TabShortName(Idx + 1) + ' >'
  else
    ButtonNext.Text := 'Next';
end;

procedure TForm1.ButtonHelpClick(Sender: TObject);
var
  Msg: string;
  OldTitle: string;
begin
  Msg := HelpTextForTab(TabControl1.TabIndex);
  if Msg = '' then
    Msg := 'No help has been written for this page yet.';
  // The FMX message dialog takes its caption from Application.Title, so borrow
  // it for the duration of the dialog; otherwise it shows the project name.
  OldTitle := Application.Title;
  Application.Title := 'Help';
  try
    ShowMessage(PageTitleForTab(TabControl1.TabIndex) + sLineBreak + sLineBreak + Msg);
  finally
    Application.Title := OldTitle;
  end;
end;
