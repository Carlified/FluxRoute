unit UGeometry;

// Small, form-independent grid/canvas geometry helpers. Extracted from the
// duplicated nested procedures that used to live inside MainWindow's paint and
// routing methods. Pure functions only - no FMX or form state.

interface

uses
  System.Types, System.Math;

// Axis-aligned rectangle overlap (grid-cell rectangles: X/Y top-left, W/H size).
function RectOverlap(X1, Y1, W1, H1, X2, Y2, W2, H2: Integer): Boolean;

// Axis direction of a grid segment: 0 = +X, 1 = -X, 2 = +Y, 3 = -Y. A
// zero-length move (via / duplicate point) returns -2; a non-axis (diagonal)
// move returns -1.
function SegDir(dx, dy: Integer): Integer;

// Unit vector for a SegDir code (0..3). Any other code yields (0, 0).
procedure DirUnit(Dir: Integer; out Ux, Uy: Integer);

// Manhattan distance between two grid points.
function Manhattan(A, B: TPoint): Integer;

implementation

function RectOverlap(X1, Y1, W1, H1, X2, Y2, W2, H2: Integer): Boolean;
begin
  Result := (X1 < X2 + W2) and (X2 < X1 + W1) and
            (Y1 < Y2 + H2) and (Y2 < Y1 + H1);
end;

function SegDir(dx, dy: Integer): Integer;
begin
  if (dx = 0) and (dy = 0) then
    Result := -2
  else if dy = 0 then
  begin
    if dx > 0 then Result := 0 else Result := 1;
  end
  else if dx = 0 then
  begin
    if dy > 0 then Result := 2 else Result := 3;
  end
  else
    Result := -1;
end;

procedure DirUnit(Dir: Integer; out Ux, Uy: Integer);
begin
  case Dir of
    0: begin Ux := 1; Uy := 0; end;
    1: begin Ux := -1; Uy := 0; end;
    2: begin Ux := 0; Uy := 1; end;
    3: begin Ux := 0; Uy := -1; end;
  else
    Ux := 0; Uy := 0;
  end;
end;

function Manhattan(A, B: TPoint): Integer;
begin
  Result := Abs(A.X - B.X) + Abs(A.Y - B.Y);
end;

end.
