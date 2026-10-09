unit uFunzioni;

interface

  uses
    Winapi.Windows,

    System.SysUtils,
    System.Classes,
    System.NetEncoding,
    System.IOUtils,

    Soap.EncdDecd,

    Vcl.Forms,

    IdCoderMIME,
    IdGlobal,
    IdHashSHA;

  function getFullPathFileIni: String;
  function getFullPathFileLog: String;

  function getBase64(AStringa: String): string;
  function getDigest(ANonce, ACreated, ACodiceapplicativo: String): string;
  function SHA1FromString(const AString: string; AMemStream: TMemoryStream): String;
  function getRandomString: string;
  function StripWhitespaces(Str: string): string;
  function DeleteLineBreaks(const AStringa: string): string;
  function CaseStringOf(const AValue: string; const ACaseList: array of string): Integer;

  Function BoleanToBoolString(AValue: Boolean): String;

  procedure Base64ToFile(const StringaBase64: AnsiString; FileName: string);

implementation

  function getFullPathFileIni: String;
    Var
      LPathApplication         : string;
      LFileNameWithoutExtension: string;
    begin

      LPathApplication          := ExtractFilePath(Application.ExeName);
      LFileNameWithoutExtension := System.IOUtils.TPath.GetFileNameWithoutExtension(Application.ExeName);

      Result := LPathApplication + LFileNameWithoutExtension + '.ini';

    end;

  function getFullPathFileLog: String;
    Var
      LPathApplication         : string;
      LFileNameWithoutExtension: string;
    begin

      LPathApplication          := ExtractFilePath(Application.ExeName);
      LFileNameWithoutExtension := System.IOUtils.TPath.GetFileNameWithoutExtension(Application.ExeName);

      Result := LPathApplication + LFileNameWithoutExtension + '.log';

    end;

  function getRandomString: string;
    var
      LTmpStr: string;
    begin

      Result := '';

      Randomize;

      LTmpStr := 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

      repeat
        Result := Result + LTmpStr[Random(Length(LTmpStr)) + 1];
      until (Length(Result) = 20);

    end;

  function SHA1FromString(const AString: string; AMemStream: TMemoryStream): String;
    var
      LIdEncoderMIME : TIdEncoderMIME;
      LSHA           : TIdHashSHA1;
      LByteApplDigest: TIdBytes;

    begin

      Result := '';

      LIdEncoderMIME          := TIdEncoderMIME.Create(nil);
      LIdEncoderMIME.name     := 'IdEncoderMIME';
      LIdEncoderMIME.FillChar := '=';

      LSHA := TIdHashSHA1.Create;

      try

        if AString <> EmptyStr then
          begin
            LByteApplDigest := LSHA.HashString(AString);
            Result          := LIdEncoderMIME.EncodeBytes(LByteApplDigest);
          end
        else
          begin
            Result := LIdEncoderMIME.Encode(AMemStream);
          end;

      finally

        if AString <> EmptyStr then
          begin
            ZeroMemory(@LByteApplDigest[0], SizeOf(LByteApplDigest));
          end;

        LSHA.Free;
        LIdEncoderMIME.Free;

      end;

    end;

  function getDigest(ANonce: String; ACreated: String; ACodiceapplicativo: String): string;

    begin

      Result := SHA1FromString(ANonce + ACreated + ACodiceapplicativo, nil);

    end;

  function getBase64(AStringa: String): string;
    begin

      Result := TNetEncoding.Base64.Encode(AStringa);

    end;

  function StripWhitespaces(Str: string): string;
    var
      i: Integer;
    begin

      i := 0;

      while i <= Length(Str) do
        if Str[i] = ' ' then
          Delete(Str, i, 1)
        else
          Inc(i);

      Result := Str;

    end;

  function DeleteLineBreaks(const AStringa: string): string;
    var
      Source, SourceEnd: PChar;
    begin

      Source    := Pointer(AStringa);
      SourceEnd := Source + Length(AStringa);

      while Source < SourceEnd do
        begin
          case Source^ of
            #10:
              Source^ := #32;
            #13:
              Source^ := #32;
          end;
          Inc(Source);
        end;
      Result := AStringa;

    end;

  function CaseStringOf(const AValue: string; const ACaseList: array of string): Integer;
    begin

      for Result := 0 to High(ACaseList) do
        if ACaseList[Result] = AValue then
          exit;

      Result := -1;

    end;

  procedure Base64ToFile(const StringaBase64: AnsiString; FileName: string);
    var
      Stream: TFileStream;
      bytes : TBytes;
    begin
      bytes  := DecodeBase64(StringaBase64);
      Stream := TFileStream.Create(FileName, fmCreate);
      try
        if bytes <> nil then
          Stream.Write(bytes[0], Length(bytes));
      finally
        Stream.Free;
      end;
    end;

  Function BoleanToBoolString(AValue: Boolean): String;
    begin

      if AValue = true then
        Result := 'True'
      else
        Result := 'False';

    end;

end.
