unit PlacementTypes;

// Domain types for the floorplan / placement stage. Extracted from MainWindow's
// type block so other units can reason about placement without pulling in the
// form.

interface

uses
  LefLibrary,
  BlifLibrary;

type
  // One block of the floorplanning grid (for future maze routing). The _Fill
  // kinds mark space extended out to the row extremities after the allocated
  // width (drawn lighter; the allocated/fill split is not stored beyond these
  // kinds).
  TFloorplanCell = (fcEmpty, fcLogic, fcClock, fcBias, fcLogicFill, fcClockFill);

  // A placed logic component: its grid cell inside the floorplan.
  TPlacedComponent = record
    Gate: TGateInstance;
    InstanceName: string;
    CellName: string;
    ClockLevel: Integer;
    X, Y: Integer; // top-left grid cell of the component
    W, H: Integer; // component size in grid cells (cell width/height / core)
  end;

  // One power port of a placed cell on a given edge, in grid coordinates. Used
  // to partition the row's bias demand into groups and to route the bias lines.
  TBiasPort = record
    Gate: TGateInstance;
    Edge: TPortEdge; // peTop or peBottom
    X, Y: Integer;   // port grid block (the offshoot connects here)
    CurrentUa: Double;
  end;

  // One partition of a channel's side: the ports it contains (left to right)
  // plus the total current it must carry.
  TBiasGroup = record
    Ports: TArray<TBiasPort>; // the group's ports, in placement order
    TotalUa: Double;
  end;

  // Immobile I/O anchor: an external input/output net pinned to a grid block
  // at the top/bottom of the die. Used to anchor the barycentre relaxation so
  // the layout cannot float freely.
  TPadConnection = record
    NetName: string;
    X, Y: Integer; // grid cell (single block, for now)
    IsInput: Boolean;
  end;

  // One placed clock-tree cell: a real splitter/buffer (interior) or a clocked
  // leaf. Children index the containing layer's node array.
  TPlacedClockNode = record
    Gate: TGateInstance;
    IsLeaf: Boolean;
    X, Y: Integer; // top-left grid cell
    W, H: Integer; // real cell footprint in grid cells
    Band: Integer; // layer-band this node is placed in (interior nodes)
    Children: TArray<Integer>;
  end;

  // One placed spine (clock trunk) component: a junction splitter or a stage
  // buffer. Trunk cells are rotated 90 deg CCW (the cell top faces the bias
  // line), so the placed footprint swaps width and height (W = cell height,
  // H = cell width). Overflow buffers lie on a band's clock row, unrotated.
  TSpineComponent = record
    Gate: TGateInstance;
    IsJunction: Boolean;
    X, Y: Integer; // top-left grid cell
    W, H: Integer; // placed footprint
    Rotated: Boolean;
    Band: Integer; // -1 = in the trunk; else the overflow band index
  end;

  // Snapshot of a placed cell's horizontal position relative to its row, used to
  // preserve the optimized placement when the bias lines are expanded (the
  // geometry rebuild must not reshuffle the cells horizontally).
  TPlaceSnapshot = record
    Gate: TGateInstance;
    X: Integer; // X offset from the row's left edge at snapshot time
  end;

implementation

end.
