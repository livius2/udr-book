﻿unit JsonFunc;

{$IFDEF FPC}
{$MODE objfpc}{$H+}
{$DEFINE DEBUGFPC}
{$ENDIF}

interface

uses
  Firebird,
  UdrFactories,
  FbTypes,
  FbCharsets,
  SysUtils,
  System.NetEncoding,
  System.Json;

// *********************************************************
// create function GetJson (
// sql_text blob sub_type text,
// sql_dialect smallint not null default 3
// ) returns blob sub_type text character set utf8
// external name 'JsonUtils!getJson'
// engine udr;
// *********************************************************

type

  TInput = record
    SqlText: ISC_QUAD;
    SqlNull: WordBool;
    SqlDialect: Smallint;
    SqlDialectNull: WordBool;
  end;

  InputPtr = ^TInput;

  TOutput = record
    Json: ISC_QUAD;
    NullFlag: WordBool;
  end;

  OutputPtr = ^TOutput;

  // Внешняя функция TSumArgsFunction.
  TJsonFunction = class(IExternalFunctionImpl)
  public
    procedure dispose(); override;

    procedure getCharSet(AStatus: IStatus; AContext: IExternalContext;
      AName: PAnsiChar; ANameSize: Cardinal); override;

    { Преобразует целое в строку в соответсвии с масштабом

      @param(AValue Значение)
      @param(Scale Масштаб)
      @returns(Строковое представление масштабированного целого)
    }
    function MakeScaleInteger(AValue: Int64; Scale: Smallint): string;

    { Добавляет закодированную запись в массив объектов Json

      @param(AStatus Статус вектор)
      @param(AContext Контекст выполнения внешней функции)
      @param(AJson Массив объектов Json)
      @param(ABuffer Буфер записи)
      @param(AMeta Метаданые курсора)
      @param(AFormatSetting Установки формата даты и времени)
    }
    procedure writeJson(AStatus: IStatus; AContext: IExternalContext;
      AJson: TJsonArray; ABuffer: PByte; AMeta: IMessageMetadata;
      AFormatSettings: TFormatSettings);

    { Выполнение внешней функции

      @param(AStatus Статус вектор)
      @param(AContext Контекст выполнения внешней функции)
      @param(AInMsg Указатель на входное сообщение)
      @param(AOutMsg Указатель на выходное сообщение)
    }
    procedure execute(AStatus: IStatus; AContext: IExternalContext;
      AInMsg: Pointer; AOutMsg: Pointer); override;
  end;

implementation

uses
  Classes, FbBlob;

const
  SQL_DIALECT_V6 = 3;

  { TJsonFunction }

procedure TJsonFunction.dispose;
begin
  Destroy;
end;

procedure TJsonFunction.execute(AStatus: IStatus; AContext: IExternalContext;
  AInMsg, AOutMsg: Pointer);
var
  xFormatSettings: TFormatSettings;
  xInput: InputPtr;
  xOutput: OutputPtr;
  att: IAttachment;
  tra: ITransaction;
  stmt: IStatement;
  inBlob, outBlob: IBlob;
  inStream: TBytesStream;
  outStream: TStringStream;
  cursorMetaData: IMessageMetadata;
  rs: IResultSet;
  msgLen: Cardinal;
  msg: Pointer;
  jsonArray: TJsonArray;
begin
  xInput := AInMsg;
  xOutput := AOutMsg;
  // если один из входных аргументов NULL, то и результат NULL
  if xInput.SqlNull or xInput.SqlDialectNull then
  begin
    xOutput.NullFlag := True;
    Exit;
  end;
  xOutput.NullFlag := False;
  // установки форматирования даты и времени
  xFormatSettings := TFormatSettings.Create;
  xFormatSettings.DateSeparator := '-';
  xFormatSettings.TimeSeparator := ':';
  // создаём поток байт для чтения blob
  inStream := TBytesStream.Create(nil);
  outStream := TStringStream.Create('', 65001);
  jsonArray := TJsonArray.Create;
  // получение текущего соединения и транзакции
  att := AContext.getAttachment(AStatus);
  tra := AContext.getTransaction(AStatus);
  stmt := nil;
  inBlob := nil;
  outBlob := nil;
  try
    // читаем BLOB в поток
    inBlob := att.openBlob(AStatus, tra, @xInput.SqlText, 0, nil);
    inBlob.SaveToStream(AStatus, inStream);
    inBlob.close(AStatus);
    // подготавливаем оператор
    stmt := att.prepare(AStatus, tra, inStream.Size, @inStream.Bytes[0],
      xInput.SqlDialect, IStatement.PREPARE_PREFETCH_METADATA);
    // получаем выходные метаданные курсора
    cursorMetaData := stmt.getOutputMetadata(AStatus);
    // откурываем курсор
    rs := stmt.openCursor(AStatus, tra, nil, nil, nil, 0);
    // выделяем буфер нужного размера
    msgLen := cursorMetaData.getMessageLength(AStatus);
    msg := AllocMem(msgLen);
    try
      // читаем каждую запись курсора
      while rs.fetchNext(AStatus, msg) = IStatus.RESULT_OK do
      begin
        // и пишем её в JSON
        writeJson(AStatus, AContext, jsonArray, msg, cursorMetaData, xFormatSettings);
      end;
    finally
      // освобождаем буфер
      FreeMem(msg);
    end;
    // закрываем курсор
    rs.close(AStatus);
    // пишем JSON в поток
    outStream.WriteString(jsonArray.ToJSON);

    // пишем json в выходной blob
    outBlob := att.createBlob(AStatus, tra, @xOutput.Json, 0, nil);
    outBlob.LoadFromStream(AStatus, outStream);
    outBlob.close(AStatus);
  finally
    if Assigned(inBlob) then
      inBlob.release;
    if Assigned(stmt) then
      stmt.release;
    if Assigned(outBlob) then
      outBlob.release;
    tra.release;
    att.release;
    jsonArray.Free;
    inStream.Free;
    outStream.Free;
  end;
end;

procedure TJsonFunction.getCharSet(AStatus: IStatus; AContext: IExternalContext;
  AName: PAnsiChar; ANameSize: Cardinal);
begin
end;

function TJsonFunction.MakeScaleInteger(AValue: Int64; Scale: Smallint): string;
var
  L: Integer;
begin
  Result := AValue.ToString;
  L := Result.Length;
  if (-Scale >= L) then
    Result := '0.' + Result.PadLeft(-Scale, '0')
  else
    Result := Result.Insert(Scale + L, '.');
end;

procedure TJsonFunction.writeJson(AStatus: IStatus; AContext: IExternalContext;
  AJson: TJsonArray; ABuffer: PByte; AMeta: IMessageMetadata;
  AFormatSettings: TFormatSettings);
var
  jsonObject: TJsonObject;
  i: Integer;
  FieldName: string;
  NullFlag: WordBool;
  pData: PByte;
  util: IUtil;
  metaLength: Integer;
  // типы
  CharBuffer: array [0 .. 35766] of Byte;
  charLength: Smallint;
  charset: TFBCharSet;
  StringValue: string;
  SmallintValue: Smallint;
  IntegerValue: Integer;
  BigintValue: Int64;
  Scale: Smallint;
  SingleValue: Single;
  DoubleValue: Double;
  BooleanValue: Boolean;
  DateValue: ISC_DATE;
  TimeValue: ISC_TIME;
  TimestampValue: ISC_TIMESTAMP;
  DateTimeValue: TDateTime;
  year, month, day: Cardinal;
  hours, minutes, seconds, fractions: Cardinal;
  blobId: ISC_QUADPtr;
  BlobSubtype: Smallint;
  blob: IBlob;
  textStream: TStringStream;
  binaryStream: TBytesStream;
  att: IAttachment;
  tra: ITransaction;
begin
  // Получаем IUtil
  util := AContext.getMaster().getUtilInterface();
  // Создаём объект TJsonObject в которой будем
  // записывать значение полей записи
  jsonObject := TJsonObject.Create;
  for i := 0 to AMeta.getCount(AStatus) - 1 do
  begin
    // получаем алиас поля в запросе
    FieldName := AMeta.getAlias(AStatus, i);
    NullFlag := PWordBool(ABuffer + AMeta.getNullOffset(AStatus, i))^;
    if NullFlag then
    begin
      // если NULL пишем его в JSON и переходим к следующему полю
      jsonObject.AddPair(FieldName, TJsonNull.Create);
      continue;
    end;
    // получаем указатель на данные поля
    pData := ABuffer + AMeta.getOffset(AStatus, i);
    case TFBType(AMeta.getType(AStatus, i)) of
      // VARCHAR
      SQL_VARYING:
        begin
          // размер буфера для VARCHAR
          metaLength := AMeta.getLength(AStatus, i);
          charset := TFBCharSet(AMeta.getCharSet(AStatus, i));
          // Для VARCHAR первые 2 байта - длина
          charLength := PSmallint(pData)^;
          // бинарные данные кодируем в base64
          if charset = CS_BINARY then
            StringValue := TNetEncoding.Base64.EncodeBytesToString((pData + 2),
              charLength * charset.GetCharWidth)
          else
          begin
            // копируем данные в буфер начиная со 3 байта
            Move((pData + 2)^, CharBuffer, metaLength - 2);
            StringValue := charset.GetString(TBytes(@CharBuffer), 0,
              metaLength);
            SetLength(StringValue, charLength);
          end;
          jsonObject.AddPair(FieldName, StringValue);
        end;
      // CHAR
      SQL_TEXT:
        begin
          // размер буфера для CHAR
          metaLength := AMeta.getLength(AStatus, i);
          charset := TFBCharSet(AMeta.getCharSet(AStatus, i));
          // бинарные данные кодируем в base64
          if charset = CS_BINARY then
            StringValue := TNetEncoding.Base64.EncodeBytesToString((pData + 2),
              metaLength)
          else
          begin
            // копируем данные в буфер
            Move(pData^, CharBuffer, metaLength);
            StringValue := charset.GetString(TBytes(@CharBuffer), 0,
              metaLength);
            charLength := metaLength div charset.GetCharWidth;
            SetLength(StringValue, charLength);
          end;
          jsonObject.AddPair(FieldName, StringValue);
        end;
      // FLOAT
      SQL_FLOAT:
        begin
          SingleValue := PSingle(pData)^;
          jsonObject.AddPair(FieldName, TJSONNumber.Create(SingleValue));
        end;
      // DOUBLE PRECISION
      // DECIMAL(p, s), где p = 10..15 в 1 диалекте
      SQL_DOUBLE, SQL_D_FLOAT:
        begin
          DoubleValue := PDouble(pData)^;
          jsonObject.AddPair(FieldName, TJSONNumber.Create(DoubleValue));
        end;
      // INTEGER
      // NUMERIC(p, s), где p = 1..4
      SQL_SHORT:
        begin
          Scale := AMeta.getScale(AStatus, i);
          SmallintValue := PSmallint(pData)^;
          if (Scale = 0) then
          begin
            jsonObject.AddPair(FieldName, TJSONNumber.Create(SmallintValue));
          end
          else
          begin
            StringValue := MakeScaleInteger(SmallintValue, Scale);
            jsonObject.AddPair(FieldName, TJSONNumber.Create(StringValue));
          end;
        end;
      // INTEGER
      // NUMERIC(p, s), где p = 5..9
      // DECIMAL(p, s), где p = 1..9
      SQL_LONG:
        begin
          Scale := AMeta.getScale(AStatus, i);
          IntegerValue := PInteger(pData)^;
          if (Scale = 0) then
          begin
            jsonObject.AddPair(FieldName, TJSONNumber.Create(IntegerValue));
          end
          else
          begin
            StringValue := MakeScaleInteger(IntegerValue, Scale);
            jsonObject.AddPair(FieldName, TJSONNumber.Create(StringValue));
          end;
        end;
      // BIGINT
      // NUMERIC(p, s), где p = 10..18 в 3 диалекте
      // DECIMAL(p, s), где p = 10..18 в 3 диалекте
      SQL_INT64:
        begin
          Scale := AMeta.getScale(AStatus, i);
          BigintValue := Pint64(pData)^;
          if (Scale = 0) then
          begin
            jsonObject.AddPair(FieldName, TJSONNumber.Create(BigintValue));
          end
          else
          begin
            StringValue := MakeScaleInteger(BigintValue, Scale);
            jsonObject.AddPair(FieldName, TJSONNumber.Create(StringValue));
          end;
        end;
      // TIMESTAMP
      SQL_TIMESTAMP:
        begin
          TimestampValue := PISC_TIMESTAMP(pData)^;
          // получаем составные части даты-времени
          util.decodeDate(TimestampValue.date, @year, @month, @day);
          util.decodeTime(TimestampValue.time, @hours, @minutes, @seconds,
            @fractions);
          // получаем дату-время в родном типе Delphi
          DateTimeValue := EncodeDate(year, month, day) +
            EncodeTime(hours, minutes, seconds, fractions div 10);
          // форматируем дату-время по заданному формату
          StringValue := FormatDateTime('yyyy/mm/dd hh:nn:ss', DateTimeValue,
            AFormatSettings);
          jsonObject.AddPair(FieldName, StringValue);
        end;
      // DATE
      SQL_DATE:
        begin
          DateValue := PISC_DATE(pData)^;
          // получаем составные части даты
          util.decodeDate(DateValue, @year, @month, @day);
          // получаем дату в родном типе Delphi
          DateTimeValue := EncodeDate(year, month, day);
          // форматируем дату по заданному формату
          StringValue := FormatDateTime('yyyy/mm/dd', DateTimeValue,
            AFormatSettings);
          jsonObject.AddPair(FieldName, StringValue);
        end;
      // TIME
      SQL_TIME:
        begin
          TimeValue := PISC_TIME(pData)^;
          // получаем составные части времени
          util.decodeTime(TimeValue, @hours, @minutes, @seconds, @fractions);
          // получаем время в родном типе Delphi
          DateTimeValue := EncodeTime(hours, minutes, seconds,
            fractions div 10);
          // форматируем время по заданному формату
          StringValue := FormatDateTime('hh:nn:ss', DateTimeValue,
            AFormatSettings);
          jsonObject.AddPair(FieldName, StringValue);
        end;
      // BOOLEAN
      SQL_BOOLEAN:
        begin
          BooleanValue := PBoolean(pData)^;
          jsonObject.AddPair(FieldName, TJsonBool.Create(BooleanValue));
        end;
      // BLOB
      SQL_BLOB, SQL_QUAD:
        begin
          BlobSubtype := AMeta.getSubType(AStatus, i);
          blobId := ISC_QUADPtr(pData);
          att := AContext.getAttachment(AStatus);
          tra := AContext.getTransaction(AStatus);
          blob := att.openBlob(AStatus, tra, blobId, 0, nil);
          if BlobSubtype = 1 then
          begin
            // текст
            charset := TFBCharSet(AMeta.getCharSet(AStatus, i));
            // создаём поток с заданой кодировкой
            textStream := TStringStream.Create('', charset.GetCodePage);
            try
              blob.SaveToStream(AStatus, textStream);
              StringValue := textStream.DataString;
            finally
              textStream.Free;
              blob.release;
              tra.release;
              att.release
            end;
          end
          else
          begin
            // все остальные подтипытипы считаем бинарными
            binaryStream := TBytesStream.Create;
            try
              blob.SaveToStream(AStatus, binaryStream);
              // кодируем строку в base64
              StringValue := TNetEncoding.Base64.EncodeBytesToString
                (binaryStream.Memory, binaryStream.Size);
            finally
              binaryStream.Free;
              blob.release;
              tra.release;
              att.release
            end;
          end;
          jsonObject.AddPair(FieldName, StringValue);
        end;

    end;
  end;
  // добавление записи в формате Json в массив
  AJson.AddElement(jsonObject);
end;

end.