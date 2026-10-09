unit uType;

interface

type
  TVerbosity = (vbMinimale, vbDettagliata, vbDettagliataSuFile);
  TLogType = (ltMessage, ltWorning, ltError);

  TQueryType = (qtOnlySelect, qtNoDatasetResultExpected);

  TRecAttestato = record
    NomeTemplateFile: String;
    UserId: Integer;
    CourseId: Integer;
    NomeCognome: String;
    DataNascita: String;
    LuogoNascita: String;
    NomeCorso: String;
    DataRilascioAttestato: String;
    NumRegistro: String;
  end;

implementation

end.
