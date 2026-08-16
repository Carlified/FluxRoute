program PnRGUI;

uses
  System.StartUpCopy,
  FMX.Forms,
  MainWindow in 'MainWindow.pas' {Form1},
  CellViewer in 'CellViewer.pas',
  BlifLibrary in 'BlifLibrary.pas',
  LefLibrary in 'LefLibrary.pas',
  VerilogTiming in 'VerilogTiming.pas',
  SplitterInsert in 'SplitterInsert.pas',
  PipelineConfig in 'PipelineConfig.pas',
  PipelineAnalysis in 'PipelineAnalysis.pas',
  FlipFlopInsert in 'FlipFlopInsert.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.
