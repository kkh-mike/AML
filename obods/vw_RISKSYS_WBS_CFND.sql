USE [MYDB]
GO

/****** Object:  View [dbo].[vw_RISKSYS_WBS_CFND]    Script Date: 2026/9/11 下午 05:46:44 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

/*
SELECT * FROM MYDB.dbo.vw_RISKSYS_WBS_CFND ORDER BY 2
*/
ALTER VIEW [dbo].[vw_RISKSYS_WBS_CFND]
AS
/*
使用系統: RISKSYS 風險管理系統
程式名稱: MYDB.dbo.vw_RISKSYS_WBS_CFND
程式說明: 遞迴查詢MYWBS擔保品樹狀階層, 提供MYDB.dbo.vw_RISKSYS_WBS_VW_COL_FAC_LON Join使用。
參考程式: WBS Source: ODSP.ODDBP01.dbo.WBS_VW_COL_FAC_LON / WBS IT: 張書坤
開發人員: RISKSYS IT: 王勝玄 / MYWBS IT: 王盛禾
開發日期: 2022/03/17
修改記錄:
...
*/

WITH CFND AS
(
   --初始資料
   SELECT
          D.FAC_NODE_SEQ AS ROOT_CODE,
          D.FAC_NODE_SEQ,
          D.FAC_SUBJECT_CODE,
          D.FAC_APPV_CCY,
          D.FAC_APPV_AMT,
          D.UTILIZED_TYPE
     FROM dbo.WBS_FAC_NODE AS D
    WHERE D.FAC_NODE_SEQ IN (SELECT ND.FAC_NODE_SEQ
                               FROM dbo.WBS_COL_INFO COL
                               JOIN dbo.WBS_COL_FAC_LINK L ON L.COL_INFO_SEQ = COL.COL_INFO_SEQ
                               JOIN dbo.WBS_FAC_NODE ND ON ND.FAC_NODE_SEQ = L.FAC_NODE_SEQ
                               JOIN dbo.WBS_COL_TYPE_CD CD ON CD.COL_TYPE_SEQ = COL.COL_TYPE_SEQ
                              WHERE ND.[STATUS] = '1' --有效節點
                                AND COL.COL_STATUS = '05' --擔保品主檔狀態05有效
                            )
    UNION ALL
   --遞迴查詢
   SELECT B.ROOT_CODE,
          A.FAC_NODE_SEQ,
          A.FAC_SUBJECT_CODE,
          A.FAC_APPV_CCY,
          A.FAC_APPV_AMT,
          A.UTILIZED_TYPE
     FROM dbo.WBS_FAC_NODE AS A
    INNER JOIN CFND AS B ON B.FAC_NODE_SEQ = A.PARENT_NODE_SEQ
)

--OUTPUT
SELECT ROOT_CODE,FAC_NODE_SEQ,FAC_SUBJECT_CODE,FAC_APPV_CCY,FAC_APPV_AMT,UTILIZED_TYPE
  FROM CFND 


GO

