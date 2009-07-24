{Copyright (c) 2008 Ville Krumlinde

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.}

//Import 3DS-files

unit u3dsFile;

interface

uses ZClasses,Classes,Contnrs;

type
  TChunkInfo = record
    Id : word;
    Length,
    EndPos : longword;
  end;

  T3dsFileParser = class
  strict private
    Stream : TMemoryStream;
    procedure Status(const S : string);
    function ReadString : string;
    procedure ParseMesh(MainChunkEndPos : longword);
    procedure ParseMaterial(MainChunkEndPos: longword);
    procedure ReadChunkInfo(out Chunk : TChunkInfo);
    procedure ParseKeyframe(MainChunkEndPos: longword);
    procedure ReadXYZ(Dest: PZVector3f);
  protected
    MeshList,MaterialList : TObjectList;
    IncludeVertexColors,IncludeTextureCoords : boolean;
    IsPivotSet : boolean;
    Pivot : TZVector3f;
    constructor Create(const FileName : string);
    procedure Parse;
  public
    destructor Destroy; override;
  end;

  T3dsImport = class
  strict private
    DataFile : T3dsFileParser;
    FileName,NamePrefix : string;
    MeshScale : single;
    AutoCenter,AutoScale,InvertNormals : boolean;
    procedure ScaleAndCenter;
    function GenerateMesh(M : TObject) : TZComponent;
    function GenerateModel: TZComponent;
    procedure ApplyPivotPoint;
  public
    constructor Create(const FileName : string);
    destructor Destroy; override;
    function Import : TZComponent;
  end;


implementation

uses ZLog,SysUtils,Meshes,ZMath,Renderer,
  frm3dsImportOptions,Controls;

type
  T3dsVertex = TZVector3f;

  T3dsFace = record
    V1, V2, V3, Flag: Word;
  end;

  T3dsMaterial = class
  protected
    Name : string;
    DiffuseColor : TZColorf;
  end;

  T3dsMesh = class
  protected
    Name : string;
    NVertices : integer;
    Vertices : array of T3dsVertex;
    VertexColors : array of TZColorf;
    TextureCoords : array of TZVector2f;
    NFaces : integer;
    Faces : array of T3dsFace;
    LocalMatrix : TZMatrix4f;
    LocalOrigin : T3dsVertex;
    //Assigned the material that is assigned the most faces
    DominatingMaterial : T3dsMaterial;
    MaxFacesMaterial : integer;
    UsedMaterials : integer;
    ZMesh : TMesh;
  end;


{ T3dsFileParser }

constructor T3dsFileParser.Create(const FileName: string);
begin
  Stream := TMemoryStream.Create;
  Stream.LoadFromFile(FileName);
  MeshList := TObjectList.Create(True);
  MaterialList := TObjectList.Create(True);
  Status('Importing: ' + ExtractFileName(FileName));
end;

destructor T3dsFileParser.Destroy;
begin
  Stream.Free;
  MeshList.Free;
  MaterialList.Free;
  inherited;
end;

procedure T3dsFileParser.Parse;
var
  Chunk : TChunkInfo;
begin
  while Stream.Position<Stream.Size do
  begin
    ReadChunkInfo(Chunk);
    case Chunk.Id of
      //MAIN3DS: main chunk, contains all other chunks
      $4d4d : ;
      //EDIT3DS: 3d-object container
      $3d3d : ;
      //3d-object
      $4000 :
        begin
          ParseMesh(Chunk.EndPos);
        end;
      //Keyframe data
      $B000 :
        ParseKeyframe(Chunk.EndPos);
      //Material
      $AFFF :
        ParseMaterial(Chunk.EndPos);
    else
      Stream.Position := Chunk.EndPos;
    end;
  end;
end;

procedure T3dsFileParser.ParseKeyframe(MainChunkEndPos: longword);
var
  Chunk : TChunkInfo;
begin
  while Stream.Position<MainChunkEndPos do
  begin
    ReadChunkInfo(Chunk);
    case Chunk.Id of
      $B002 : //Object node tag
        ;
      $B013 : //PIVOT
        begin
          if not IsPivotSet then
          begin
            ReadXYZ(@Pivot);
            Status( Format('Pivot: %.2f %.2f %.2f',[Pivot[0],Pivot[1],Pivot[2]]) );
            IsPivotSet := True;
          end
          else
            Stream.Seek(SizeOf(Pivot),soFromCurrent);
        end
    else
      Stream.Position := Chunk.EndPos;
    end;
  end;
end;

procedure T3dsFileParser.ParseMaterial(MainChunkEndPos: longword);
var
  Material : T3dsMaterial;
  Chunk : TChunkInfo;
  B : byte;
  PColor : PColorf;
begin
  Material := T3dsMaterial.Create;
  MaterialList.Add(Material);
  PColor := nil;
  while Stream.Position<MainChunkEndPos do
  begin
    ReadChunkInfo(Chunk);
    case Chunk.Id of
      $A000 : //Name
        begin
          Material.Name := ReadString;
          Status('Material: ' + Material.Name);
        end;
      $A020 : //Diffuse color
        PColor := @Material.DiffuseColor;
      $0011 : //Color 24
        begin
          Stream.Read(B,1);
          PColor^.R := B / 255;
          Stream.Read(B,1);
          PColor^.G := B / 255;
          Stream.Read(B,1);
          PColor^.B := B / 255;
        end
    else
      Stream.Position := Chunk.EndPos;
    end;
  end;
end;

procedure T3dsFileParser.ReadXYZ(Dest : PZVector3f);
begin
  //3ds xyz are different to zzdc coordinate system
  Stream.Read(Dest^[0],4);
  Stream.Read(Dest^[2],4);
  Dest^[2] := Dest^[2] * -1;   //Invert Y-axis 
  Stream.Read(Dest^[1],4);
end;

procedure T3dsFileParser.ParseMesh(MainChunkEndPos: longword);
var
  Mesh : T3dsMesh;
  Chunk : TChunkInfo;
  W :  word;
  I,J,MaterialI : integer;
  S : string;
  Faces : array of word;
begin
  Mesh := T3dsMesh.Create;
  MeshList.Add(Mesh);
  Mesh.Name := ReadString;
  Status('Mesh: ' + Mesh.Name);
  while Stream.Position<MainChunkEndPos do
  begin
    ReadChunkInfo(Chunk);
    case Chunk.Id of
      //TRIMESH
      $4100 : ;
      //Vertices list
      $4110 :
        begin
          Stream.Read(W,2);
          Mesh.NVertices := W;
          SetLength(Mesh.Vertices,W);
          SetLength(Mesh.VertexColors,W);
          for I := 0 to Mesh.NVertices - 1 do
            ReadXYZ(@Mesh.Vertices[I]);
        end;
      //Faces list
      $4120 :
        begin
          Stream.Read(W,2);
          Mesh.NFaces := W;
          SetLength(Mesh.Faces,W);
          for I := 0 to Mesh.NFaces - 1 do
          begin
            Stream.Read(Mesh.Faces[I].V1,2);
            Stream.Read(Mesh.Faces[I].V2,2);
            Stream.Read(Mesh.Faces[I].V3,2);
            Stream.Read(Mesh.Faces[I].Flag,2);
          end;
        end;
      //Mesh material assign
      $4130 :
        begin
          Inc(Mesh.UsedMaterials);
          S := ReadString; //Material name

          //Find material
          MaterialI := -1;
          for I := 0 to MaterialList.Count - 1 do
          begin
            if T3dsMaterial(MaterialList[I]).Name=S then
            begin
              MaterialI := I;
              Break;
            end;
          end;

          Stream.Read(W,2); //Number of faces to assign this material
          if IncludeVertexColors then
          begin
            SetLength(Faces,W);
            Stream.Read(Faces[0],W*2);
            for I := 0 to High(Faces) do
            begin
              Mesh.VertexColors[ Mesh.Faces[ Faces[I] ].V1 ] := T3dsMaterial(MaterialList[MaterialI]).DiffuseColor;
              Mesh.VertexColors[ Mesh.Faces[ Faces[I] ].V2 ] := T3dsMaterial(MaterialList[MaterialI]).DiffuseColor;
              Mesh.VertexColors[ Mesh.Faces[ Faces[I] ].V3 ] := T3dsMaterial(MaterialList[MaterialI]).DiffuseColor;
            end;
          end
          else
            //Skip past all the faceids
            Stream.Seek(W*2,soFromCurrent);
          //Assign material to mesh if this occupies the most faces
          if (W>Mesh.MaxFacesMaterial) and (MaterialI>-1) then
          begin
            Mesh.MaxFacesMaterial := W;
            Mesh.DominatingMaterial := T3dsMaterial(MaterialList[MaterialI]);
          end;
        end;
      $4140 :
        //Texture coords
        begin
          if IncludeTextureCoords then
          begin
            Stream.Read(W,2);
            if W<>Mesh.NVertices then
              Status('** Texcoord count differs from vertice count');
            SetLength(Mesh.TextureCoords,W);
            Stream.Read(Mesh.TextureCoords[0],W * SizeOf(TZVector2f) );
          end
          else
            Stream.Position := Chunk.EndPos;
        end;
      //Transform Matrix
      $4160 :
        begin
          //All vertices mesh are already transformed with this matrix
          for J := 0 to 2 do
            for I := 0 to 2 do
              Stream.Read(Mesh.LocalMatrix[J][I],4);
          ReadXYZ(@Mesh.LocalOrigin);
          Status( Format('LocalOrigin: %.2f %.2f %.2f',[Mesh.LocalOrigin[0],Mesh.LocalOrigin[1],Mesh.LocalOrigin[2]]) );
        end;
    else
      Stream.Position := Chunk.EndPos;
    end;
  end;
end;

procedure T3dsFileParser.ReadChunkInfo(out Chunk: TChunkInfo);
begin
  Stream.Read(Chunk.Id,2);
  Stream.Read(Chunk.Length,4);
  Chunk.EndPos := Stream.Position + Chunk.Length - 6;
//  Status('Reading chunk: ' + IntToStr(Chunk.Id));
end;

function T3dsFileParser.ReadString: string;
var
  Len: Integer;
  Buffer: array[Byte] of Char;
begin
  Len := 0;
  repeat
    Stream.Read(Buffer[Len], 1);
    Inc(Len);
    if Len=High(Byte) then
      raise Exception.Create('Invalid 3ds-string');
  until Buffer[Len - 1] = #0;
  SetString(Result, Buffer, Len - 1); // not the null byte
end;

procedure T3dsFileParser.Status(const S: string);
begin
  ZLog.GetLog(Self.ClassName).Write( S );
end;

{ T3dsImport }

constructor T3dsImport.Create(const FileName: string);
begin
  Self.DataFile := T3dsFileParser.Create(FileName);
  Self.FileName := FileName;
end;

destructor T3dsImport.Destroy;
begin
  DataFile.Free;
  inherited;
end;

function T3dsImport.GenerateMesh(M: TObject): TZComponent;
var
  InMesh : T3dsMesh;
  OutMesh : TMesh;
  MeshImp : TMeshImport;
  I,Color : integer;
  Stream,StU,StV : TMemoryStream;
  MinV,MaxV,DiffV : TZVector3f;
  W : word;
  Sm : smallint;
begin
  InMesh := T3dsMesh(M);

  OutMesh := TMesh.Create(nil);
  OutMesh.Comment := InMesh.Name;
  OutMesh.Name := NamePrefix + 'Mesh' + IntToStr(DataFile.MeshList.IndexOf(M));

  MeshImp := TMeshImport.Create(OutMesh.Producers);
  MeshImp.Scale := Vector3f(Self.MeshScale,Self.MeshScale,Self.MeshScale);

  Stream := TMemoryStream.Create;
  try
    Stream.Write(InMesh.NVertices,4);
    Stream.Write(InMesh.NFaces,4);

    //Quantize vertices to 16-bit values
    MinV := Vector3f(100000,100000,100000);
    MaxV := Vector3f(0,0,0);
    for I := 0 to InMesh.NVertices - 1 do
    begin
      MinV[0] := Min(MinV[0],InMesh.Vertices[I][0]);
      MinV[1] := Min(MinV[1],InMesh.Vertices[I][1]);
      MinV[2] := Min(MinV[2],InMesh.Vertices[I][2]);
      MaxV[0] := Max(MaxV[0],InMesh.Vertices[I][0]);
      MaxV[1] := Max(MaxV[1],InMesh.Vertices[I][1]);
      MaxV[2] := Max(MaxV[2],InMesh.Vertices[I][2]);
    end;

    Stream.Write(MinV,3*4);
    ZMath.VecSub3(MaxV,MinV,DiffV);
    Stream.Write(DiffV,3*4);

    for I := 0 to InMesh.NVertices - 1 do
    begin
      W := Round( (InMesh.Vertices[I][0] - MinV[0]) / DiffV[0] * High(Word) );
      Stream.Write(W,2);
      W := Round( (InMesh.Vertices[I][1] - MinV[1]) / DiffV[1] * High(Word) );
      Stream.Write(W,2);
      W := Round( (InMesh.Vertices[I][2] - MinV[2]) / DiffV[2] * High(Word) );
      Stream.Write(W,2);
    end;

    if InvertNormals then
      for I := 1 to InMesh.NFaces - 1 do
      begin
        W := InMesh.Faces[I].V1;
        InMesh.Faces[I].V1 := InMesh.Faces[I].V3;
        InMesh.Faces[I].V3 := W;
      end;

    //Delta-encode indices
    Sm := InMesh.Faces[0].V1;
    Stream.Write(Sm,2);
    Sm := InMesh.Faces[0].V2;
    Stream.Write(Sm,2);
    Sm := InMesh.Faces[0].V3;
    Stream.Write(Sm,2);
    for I := 1 to InMesh.NFaces - 1 do
    begin
      Sm := InMesh.Faces[I].V1 - InMesh.Faces[I-1].V1;
      Stream.Write(Sm,2);
      Sm := InMesh.Faces[I].V2 - InMesh.Faces[I-1].V2;
      Stream.Write(Sm,2);
      Sm := InMesh.Faces[I].V3 - InMesh.Faces[I-1].V3;
      Stream.Write(Sm,2);
    end;

    if DataFile.IncludeVertexColors and (InMesh.UsedMaterials>1) then
    begin
      MeshImp.HasVertexColors := True;
      for I := 0 to InMesh.NVertices - 1 do
      begin
        Color := (Round(InMesh.VertexColors[I].B * 255) shl 16) or
          (Round(InMesh.VertexColors[I].G * 255) shl 8) or
          Round(InMesh.VertexColors[I].R * 255);
        Stream.Write(Color,4);
      end;
    end;

    if DataFile.IncludeTextureCoords and (Length(InMesh.TextureCoords)>0) then
    begin
      MeshImp.HasTextureCoords := True;
      StU := TMemoryStream.Create;
      StV := TMemoryStream.Create;

      //Delta-encode in separate streams
      W := Round( Frac(InMesh.TextureCoords[0][0]) * High(Smallint) );
      StU.Write(W,2);
      W := Round( Frac(InMesh.TextureCoords[0][1]) * High(Smallint) );
      StV.Write(W,2);

      for I := 1 to High(InMesh.TextureCoords) do
      begin
        Sm := Round( (InMesh.TextureCoords[I][0]-InMesh.TextureCoords[I-1][0]) * High(SmallInt) );
        StU.Write(Sm,2);
        Sm := Round( (InMesh.TextureCoords[I][1]-InMesh.TextureCoords[I-1][1]) * High(SmallInt) );
        StV.Write(Sm,2);
      end;
      StU.SaveToStream(Stream);
      StV.SaveToStream(Stream);
      StU.Free;
      StV.Free;
      //Stream.Write(InMesh.TextureCoords[0],8 * InMesh.NVertices);
    end;

    //Write data to binary property
    GetMem(MeshImp.MeshData.Data,Stream.Size);
    MeshImp.MeshData.Size := Stream.Size;
    Stream.Position := 0;
    Stream.Read(MeshImp.MeshData.Data^,Stream.Size)
  finally
    Stream.Free;
  end;

  InMesh.ZMesh := OutMesh;

  Result := OutMesh;
end;

function T3dsImport.GenerateModel : TZComponent;
var
  M : TModel;
  Mesh : T3dsMesh;
  I : integer;
  RMesh : TRenderMesh;
  SColor : TRenderSetColor;
begin
  M := TModel.Create(nil);
  for I := 0 to DataFile.MeshList.Count - 1 do
  begin
    Mesh := DataFile.MeshList[I] as T3dsMesh;
    if Mesh.ZMesh=nil then
      Continue;

    if ((not DataFile.IncludeVertexColors) or (Mesh.UsedMaterials=1)) and
      (Mesh.DominatingMaterial<>nil) then
    begin
      SColor := TRenderSetColor.Create(M.OnRender);
      SColor.Color := Mesh.DominatingMaterial.DiffuseColor;
    end;

    RMesh := TRenderMesh.Create(M.OnRender);
    RMesh.Mesh := Mesh.ZMesh;
  end;
  M.Name := NamePrefix + 'Model';
  Result := M;
end;

function T3dsImport.Import: TZComponent;
var
  Group,MeshGroup : TLogicalGroup;
  I : integer;
  Mesh : T3dsMesh;
  F : TImport3dsForm;
begin
  F := TImport3dsForm.Create(nil);
  try
    F.NamePrefixEdit.Text := ChangeFileExt(ExtractFileName(Self.FileName),'');
    if F.ShowModal=mrCancel then
      Abort;
    Self.NamePrefix := F.GetValidatedName(F.NamePrefixEdit.Text);
    Self.MeshScale := StrToIntDef(F.MeshScaleEdit.Text,100) / 100.0;
    Self.DataFile.IncludeVertexColors := F.ColorsCheckBox.Checked;
    Self.AutoCenter := F.AutoCenterCheckBox.Checked;
    Self.AutoScale := F.AutoScaleCheckBox.Checked;
    Self.InvertNormals := F.InvertNormalsCheckBox.Checked;
    Self.DataFile.IncludeTextureCoords := F.TexCoordsCheckBox.Checked;
  finally
    F.Free;
  end;

  Self.DataFile.Parse;

  if not AutoCenter then
    ApplyPivotPoint;

  if AutoScale or AutoCenter then
    ScaleAndCenter;

  Group := TLogicalGroup.Create(nil);

  MeshGroup := TLogicalGroup.Create(Group.Children);
  MeshGroup.Comment := 'Meshes';
  for I := 0 to DataFile.MeshList.Count - 1 do
  begin
    Mesh := DataFile.MeshList[I] as T3dsMesh;
    //Some meshes are faulty, others are lights or cameras without geometry
    if Mesh.NVertices>2 then
      MeshGroup.Children.AddComponent( GenerateMesh(Mesh) );
  end;

  Group.Children.AddComponent( GenerateModel );
  Group.Comment := 'Imported from ' + ExtractFileName(Self.FileName);

  Result := Group;
end;

procedure T3dsImport.ScaleAndCenter;
var
  MinV,MaxV,DV,ScaleV,TransV,V : TZVector3f;
  I,J : integer;
  Mesh : T3dsMesh;

  Mat : TZMatrix4f;
  Scale : single;
begin
  MinV := Vector3f(10000,10000,10000);
  MaxV := Vector3f(-10000,-10000,-10000);
  for I := 0 to DataFile.MeshList.Count - 1 do
  begin
    Mesh := T3dsMesh(DataFile.MeshList[I]);
    for J := 0 to High(Mesh.Vertices) do
    begin
      MinV[0] := Min(MinV[0],Mesh.Vertices[J][0]);
      MinV[1] := Min(MinV[1],Mesh.Vertices[J][1]);
      MinV[2] := Min(MinV[2],Mesh.Vertices[J][2]);
      MaxV[0] := Max(MaxV[0],Mesh.Vertices[J][0]);
      MaxV[1] := Max(MaxV[1],Mesh.Vertices[J][1]);
      MaxV[2] := Max(MaxV[2],Mesh.Vertices[J][2]);
    end;
  end;
  VecSub3(MaxV,MinV,DV);

  if AutoScale then
  begin
    Scale := 1 / DV[0];
    ScaleV := Vector3f(Scale,Scale,Scale);
  end
  else
    ScaleV := Vector3f(1,1,1);

  if AutoCenter then
  begin
    VecScalarMult3(MinV,-1,V);
    VecSub3(V, VecScalarMult3(DV,0.5) ,TransV);
    VecMult3(TransV,ScaleV);
  end
  else
    TransV := Vector3f(0,0,0);

  CreateScaleAndTranslationMatrix(ScaleV, TransV, Mat);

  for I := 0 to DataFile.MeshList.Count - 1 do
  begin
    Mesh := T3dsMesh(DataFile.MeshList[I]);
    for J := 0 to High(Mesh.Vertices) do
    begin
      VectorTransform(Mesh.Vertices[J],Mat,V);
      Mesh.Vertices[J] := V;
    end;
  end;
end;

procedure T3dsImport.ApplyPivotPoint;
var
  I,J : integer;
  Mesh : T3dsMesh;
begin
exit; //todo: this needs more debugging
  for I := 0 to DataFile.MeshList.Count - 1 do
  begin
    Mesh := T3dsMesh(DataFile.MeshList[I]);
    for J := 0 to High(Mesh.Vertices) do
    begin
      VecSub3(Mesh.Vertices[J],DataFile.Pivot,Mesh.Vertices[J]);
      VecSub3(Mesh.Vertices[J],Mesh.LocalOrigin,Mesh.Vertices[J]);
    end;
  end;
end;


end.