object FrmMain: TFrmMain
  Left = 0
  Top = 0
  Caption = 'MCP Server - Gestionale Alimentare'
  ClientHeight = 454
  ClientWidth = 653
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Tahoma'
  Font.Style = []
  Position = poScreenCenter
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  TextHeight = 14
  object StatusBar: TStatusBar
    Left = 0
    Top = 435
    Width = 653
    Height = 19
    Panels = <>
    SimplePanel = True
    SimpleText = 'Server: fermo'
  end
  object PanelComandi: TPanel
    Left = 0
    Top = 0
    Width = 653
    Height = 41
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object ButtonStartServer: TButton
      Left = 8
      Top = 6
      Width = 100
      Height = 30
      Caption = 'Start Server'
      TabOrder = 0
      OnClick = ButtonStartServerClick
    end
    object ButtonStopServer: TButton
      Left = 116
      Top = 6
      Width = 100
      Height = 30
      Caption = 'Stop Server'
      TabOrder = 1
      OnClick = ButtonStopServerClick
    end
  end
  object MemoLog: TMemo
    Left = 0
    Top = 41
    Width = 653
    Height = 394
    Align = alClient
    ScrollBars = ssVertical
    TabOrder = 1
  end
end
