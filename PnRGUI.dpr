program PnRGUI;

uses
  System.SysUtils,
  System.StartUpCopy,
  FMX.Forms,
  UGeometry in 'UGeometry.pas',
  UPhysics in 'UPhysics.pas',
  UColors in 'UColors.pas',
  UNetNaming in 'UNetNaming.pas',
  URoutingLegend in 'URoutingLegend.pas',
  UDesignConfig in 'UDesignConfig.pas',
  UConstants in 'UConstants.pas',
  ExportModel in 'ExportModel.pas',
  ExportLibrary in 'ExportLibrary.pas',
  ExportGDS in 'ExportGDS.pas',
  ExportCIR in 'ExportCIR.pas',
  UPython in 'UPython.pas',
  PlacementTypes in 'PlacementTypes.pas',
  MainWindow in 'MainWindow.pas' {Form1},
  CellViewer in 'CellViewer.pas',
  BlifLibrary in 'BlifLibrary.pas',
  LefLibrary in 'LefLibrary.pas',
  VerilogTiming in 'VerilogTiming.pas',
  SplitterInsert in 'SplitterInsert.pas',
  PipelineConfig in 'PipelineConfig.pas',
  PipelineAnalysis in 'PipelineAnalysis.pas',
  FlipFlopInsert in 'FlipFlopInsert.pas',
  ClockNetwork in 'ClockNetwork.pas',
  ClockValidate in 'ClockValidate.pas',
  ProjectData in 'ProjectData.pas';

{$R *.res}

begin
  // Every number this program shows, parses or writes uses '.' as the decimal
  // separator, whatever the OS locale: the edit boxes, the log, the project
  // files and the exported JSON/CIR all agree, and the Python tools read the
  // same text. Without this a comma locale makes the config page reformat its
  // values with commas while the parser expects periods.
  FormatSettings := TFormatSettings.Invariant;

  Application.Initialize;
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.
