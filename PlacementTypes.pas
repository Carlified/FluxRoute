unit PlacementTypes;

// Domain types for the floorplan / placement stage. Extracted from MainWindow's
// type block so other units can reason about placement without pulling in the
// form.

interface

uses
  System.Types,
  LefLibrary,
  BlifLibrary;

type
  // One routed trace: the net's polyline through grid-block centres, with the
  // routing-layer name of every point. A straight run (consecutive same-layer,
  // collinear points) is a PTL (or bias) segment; a point where the layer
  // changes is a via; a direction change is a bend. Declared here (not in the
  // form) so the export enumerator can reason about the circuit without form
  // dependencies.
  TRoutedTrace = record
    NetName: string;
    Points: TArray<TPoint>;
    Layers: TArray<string>;
  end;

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

  // A length-fixing validation buffer: an overlay ("mask layer") placement that
  // sits over the normal layout but is owned by its own placer. It lives in the
  // netlist (so routing and the clock walk see it) but never in FPlacedComponents,
  // FSpine or the clock subtree. XOffset is relative to the band row's left edge,
  // so shifting a whole row keeps it valid.
  TLengthBufferPlacement = record
    Gate: TGateInstance;
    NetName: string;
    IsClock: Boolean;
    Band: Integer;
    OnClockRow: Boolean;
    XOffset: Integer;
    W, H: Integer;
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

  // One horizontal bias row the router will place: its Y, what kind of line it
  // is, the group(s) it carries and the total current it draws. Built once and
  // shared by the floorplan (to size the trunk) and the router (to place it).
  TBiasRowKind = (brGroup, brMerged, brClock);
  TBiasRow = record
    Y: Integer;
    Kind: TBiasRowKind;
    GrpA, GrpB: TBiasGroup; // GrpB used only by brMerged
    TrackX: Integer;        // clock rows only
    CurrentUa: Double;      // total current this row draws
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

  // One cell of the block-based bias network, exactly like a PTL grid cell: the
  // router tiles the bias lines cell by cell instead of as long single traces.
  // Dirs stores which of the four neighbours this cell connects to on the bias
  // layer (bit 0 = N/Y-1, 1 = E/X+1, 2 = S/Y+1, 3 = W/X-1), so the export
  // enumerator classifies bias cells into the same straight/bend/junction kinds
  // as PTL runs without any bias-specific geometry.
  TBiasCell = record
    X, Y: Integer;   // grid block
    Layer: string;   // the bias routing layer
    Dirs: Byte;      // neighbour direction bitset
    TapDirs: Byte;   // subset of Dirs that are skinny taps (not full-width)
  end;

  // Snapshot of a placed cell's horizontal position relative to its row, used to
  // preserve the optimized placement when the bias lines are expanded (the
  // geometry rebuild must not reshuffle the cells horizontally).
  TPlaceSnapshot = record
    Gate: TGateInstance;
    X: Integer;    // X offset from the row's left edge at snapshot time
    Chunk: Integer; // wrapped-row index within its layer (which band it is in)
  end;

const
  // TBiasCell.Dirs bits (cell-centre neighbours, app frame Y down).
  BiasDirN = 1;
  BiasDirE = 2;
  BiasDirS = 4;
  BiasDirW = 8;

implementation

end.
