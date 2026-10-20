object FrmMain: TFrmMain
  Left = 0
  Top = 0
  Margins.Left = 6
  Margins.Top = 6
  Margins.Right = 6
  Margins.Bottom = 6
  Caption = 'MCP Server - Gestionale Alimentare'
  ClientHeight = 908
  ClientWidth = 1306
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -24
  Font.Name = 'Tahoma'
  Font.Style = []
  Position = poScreenCenter
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  PixelsPerInch = 192
  TextHeight = 29
  object StatusBar: TStatusBar
    Left = 0
    Top = 870
    Width = 1306
    Height = 38
    Margins.Left = 6
    Margins.Top = 6
    Margins.Right = 6
    Margins.Bottom = 6
    Panels = <>
    SimplePanel = True
    SimpleText = 'Server: fermo'
  end
  object PanelComandi: TPanel
    Left = 0
    Top = 0
    Width = 1306
    Height = 82
    Margins.Left = 6
    Margins.Top = 6
    Margins.Right = 6
    Margins.Bottom = 6
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object ButtonStartServer: TButton
      Left = 16
      Top = 12
      Width = 200
      Height = 60
      Margins.Left = 6
      Margins.Top = 6
      Margins.Right = 6
      Margins.Bottom = 6
      Caption = 'Start Server'
      TabOrder = 0
      OnClick = ButtonStartServerClick
    end
    object ButtonStopServer: TButton
      Left = 232
      Top = 12
      Width = 200
      Height = 60
      Margins.Left = 6
      Margins.Top = 6
      Margins.Right = 6
      Margins.Bottom = 6
      Caption = 'Stop Server'
      TabOrder = 1
      OnClick = ButtonStopServerClick
    end
  end
  object MemoLog: TMemo
    Left = 0
    Top = 82
    Width = 1306
    Height = 788
    Margins.Left = 6
    Margins.Top = 6
    Margins.Right = 6
    Margins.Bottom = 6
    Align = alClient
    ScrollBars = ssVertical
    TabOrder = 1
  end
end
