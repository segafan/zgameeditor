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

unit ZFile;

interface

uses ZClasses;

type
  TZFile = class(TZComponent)
  private
    WriteFileName : array[0..254] of AnsiChar;
  protected
    procedure DefineProperties(List: TZPropertyList); override;
  public
    FileName : TPropString;
    FileNameFloatRef : TZPropertyRef;
    FileEmbedded : TZBinaryPropValue;
    Encoding : (feChar,feBinary);
    OnRead : TZComponentList;
    OnWrite : TZComponentList;
  end;

  TFileAction = class(TCommand)
  protected
    procedure DefineProperties(List: TZPropertyList); override;
  public
    Action : (faRead,faWrite);
    ZFile : TZFile;
    procedure Execute; override;
    {$ifndef minimal}
    function GetDisplayName: AnsiString; override;
    {$endif}
  end;

  TFileMoveData = class(TCommand)
  protected
    procedure DefineProperties(List: TZPropertyList); override;
  public
    ZProperty : TZPropertyRef;
    procedure Execute; override;
    {$ifndef minimal}
    function GetDisplayName: AnsiString; override;
    {$endif}
  end;

implementation

uses ZLog,ZPlatform;


const
  WriteBufSize=1024;
var
  CurFileState : (fsNone,fsReading,fsWriting);
  CurInStream : TZInputStream;
  CurFile : TZFile;
  CurWriteBuf : record
      Position,ByteSize : integer;
      Append : boolean;
      case Boolean of
        True : (BBuf : array[0..WriteBufSize-1] of byte);
        False : (FBuf : array[0..(WriteBufSize div 4)-1] of single);
    end;


procedure FlushWriteBuf;
begin
  Platform_WriteFile(CurFile.WriteFileName,@CurWriteBuf.BBuf,
    CurWriteBuf.ByteSize,CurWriteBuf.Append);
  CurWriteBuf.Position := 0;
  CurWriteBuf.ByteSize := 0;
  CurWriteBuf.Append := True;
end;

{ TZFile }

procedure TZFile.DefineProperties(List: TZPropertyList);
begin
  inherited;
  List.AddProperty({$IFNDEF MINIMAL}'FileName',{$ENDIF}integer(@FileName), zptString);
  List.AddProperty({$IFNDEF MINIMAL}'FileNameFloatRef',{$ENDIF}integer(@FileNameFloatRef), zptPropertyRef);
  List.AddProperty({$IFNDEF MINIMAL}'FileEmbedded',{$ENDIF}integer(@FileEmbedded), zptBinary);
  List.AddProperty({$IFNDEF MINIMAL}'Encoding',{$ENDIF}integer(@Encoding), zptByte);
    {$ifndef minimal}List.GetLast.SetOptions(['Char','Binary']);{$endif}
  List.AddProperty({$IFNDEF MINIMAL}'OnRead',{$ENDIF}integer(@OnRead), zptComponentList);
  List.AddProperty({$IFNDEF MINIMAL}'OnWrite',{$ENDIF}integer(@OnWrite), zptComponentList);
end;

{ TFileAction }

{$ifndef minimal}
const
  FileActionNames : array[0..1] of string = ('Read','Write');
{$endif}

procedure TFileAction.DefineProperties(List: TZPropertyList);
begin
  inherited;
  List.AddProperty({$IFNDEF MINIMAL}'File',{$ENDIF}integer(@ZFile), zptComponentRef);
    {$ifndef minimal}List.GetLast.SetChildClasses([TZFile]);{$endif}
    {$ifndef minimal}List.GetLast.NeedRefreshNodeName := True;{$endif}
  List.AddProperty({$IFNDEF MINIMAL}'Action',{$ENDIF}integer(@Action), zptByte);
    {$ifndef minimal}List.GetLast.SetOptions(FileActionNames);{$endif}
    {$ifndef minimal}List.GetLast.NeedRefreshNodeName := True;{$endif}
end;

procedure TFileAction.Execute;
var
  S : PAnsiChar;
  FloatBuf : array[0..15] of ansichar;
  NameBuf : array[0..254] of ansichar;
begin
  {$ifndef minimal}
  if CurFileState<>fsNone then
    //Only allow a single file-operation to be active at one time
    ZHalt('FileAction failed. CurFileState<>fsNone.');
  {$endif}

  if ZFile.FileEmbedded.Size>0 then
  begin
    {$ifndef minimal}
    if Action=faWrite then
      ZHalt('FileAction failed. Cannot write to embedded file.');
    {$endif}
    //Open file embedded in exe-file
    CurInStream := TZInputStream.CreateFromMemory(ZFile.FileEmbedded.Data,ZFile.FileEmbedded.Size);
  end
  else
  begin
    //Open external file
    if ZFile.FileNameFloatRef.Component<>nil then
    begin
      //If ref is set then convert float-value to string
      ZStrConvertFloat(
        PFloat(ZFile.FileNameFloatRef.Component.GetPropertyPtr(ZFile.FileNameFloatRef.Prop,ZFile.FileNameFloatRef.Index))^,
        PAnsiChar(@FloatBuf));
      ZStrCopy(NameBuf,PAnsiChar(ZFile.FileName));
      ZStrCat(NameBuf,PAnsiChar(@FloatBuf));
      S := PAnsiChar(@NameBuf);
    end
    else
      S := PAnsiChar(ZFile.FileName);

    {$ifdef zlog}
    ZLog.GetLog(Self.ClassName).Write('ZFile Open: ' + S);
    {$endif}

    if Action=faRead then
      CurInStream := TZInputStream.CreateFromFile(S,True)
    else
    begin
      ZStrCopy(Self.ZFile.WriteFileName,S);
      CurWriteBuf.Position := 0;
    end;
  end;

  CurFile := Self.ZFile;

  case Action of
    faRead :
      begin
      {$ifndef minimal}try{$endif}
        CurFileState := fsReading;
        ZFile.OnRead.ExecuteCommands;
      {$ifndef minimal}finally{$endif}
        CurInStream.Free;
        CurFileState := fsNone;
      {$ifndef minimal}end;{$endif}
      end;
    faWrite :
      begin
      {$ifndef minimal}try{$endif}
        CurFileState := fsWriting;
        FillChar(CurWriteBuf,SizeOf(CurWriteBuf),0);
        ZFile.OnWrite.ExecuteCommands;
        FlushWriteBuf;
      {$ifndef minimal}finally{$endif}
        CurFileState := fsNone;
      {$ifndef minimal}end;{$endif}
      end;
  end;

  {$ifndef minimal}
  CurFile := nil;
  CurInStream := nil;
  {$endif}
end;

{$ifndef minimal}
function TFileAction.GetDisplayName: AnsiString;
begin
  Result := inherited GetDisplayName;
  if Assigned(Self.ZFile) then
    Result := Result + '  ' + AnsiString(FileActionNames[ Ord(Action) ]) + ' ' + ZFile.Name;
end;
{$endif}


{ TFileMoveData }

procedure TFileMoveData.DefineProperties(List: TZPropertyList);
begin
  inherited;
  List.AddProperty({$IFNDEF MINIMAL}'Property',{$ENDIF}integer(@ZProperty), zptPropertyRef);
    {$ifndef minimal}List.GetLast.NeedRefreshNodeName := True;{$endif}
end;

procedure TFileMoveData.Execute;
var
  PropValuePtr : PFloat;
  V : single;
  B : byte;
begin
  {$ifndef minimal}
  if (CurFileState=fsNone) then
    ZHalt('FileMoveData failed. No file active.');
  if (ZProperty.Component=nil) then
    ZHalt('FileMoveData failed. No target property set.');
  {$endif}
  PropValuePtr := ZProperty.Component.GetPropertyPtr(ZProperty.Prop,ZProperty.Index);
  case CurFileState of
    fsReading :
      begin
        case CurFile.Encoding of
          feChar :
            begin
              CurInStream.Read(B,SizeOf(B));
              V := B;
            end;
          feBinary :
            CurInStream.Read(V,SizeOf(V));
        end;
        PropValuePtr^ := V;
      end;
    fsWriting :
      begin
        V := PropValuePtr^;
        case CurFile.Encoding of
          feChar :
            begin
              B := Trunc(V);
              if CurWriteBuf.Position>High(CurWriteBuf.BBuf) then
                FlushWriteBuf;
              CurWriteBuf.BBuf[CurWriteBuf.Position] := B;
              Inc(CurWriteBuf.ByteSize);
            end;
          feBinary :
            begin
              if CurWriteBuf.Position>High(CurWriteBuf.FBuf) then
                FlushWriteBuf;
              CurWriteBuf.FBuf[CurWriteBuf.Position] := V;
              Inc(CurWriteBuf.ByteSize,4);
            end;
        end;
        Inc(CurWriteBuf.Position);
      end;
  end;
end;

{$ifndef minimal}
function TFileMoveData.GetDisplayName: AnsiString;
begin
  Result := inherited GetDisplayName;
  if Assigned(ZProperty.Component) then
    Result := Result + '  ' + ZProperty.Component.Name + '.' + AnsiString(ZProperty.Prop.Name);
end;
{$endif}

initialization

  ZClasses.Register(TZFile,ZFileClassId);
    {$ifndef minimal}ComponentManager.LastAdded.ZClassName := 'File';{$endif}
    {$ifndef minimal}ComponentManager.LastAdded.HelpText := 'A file on disk for reading and writing of data';{$endif}
    {$ifndef minimal}ComponentManager.LastAdded.AutoName := True;{$endif}
  ZClasses.Register(TFileAction,FileActionClassId);
    {$ifndef minimal}ComponentManager.LastAdded.HelpText := 'Controls when to read/write from a File';{$endif}
  ZClasses.Register(TFileMoveData,FileMoveDataClassId);
    {$ifndef minimal}ComponentManager.LastAdded.HelpText := 'Move data from/to a File. Use only in File.OnRead or OnWrite.';{$endif}

end.
