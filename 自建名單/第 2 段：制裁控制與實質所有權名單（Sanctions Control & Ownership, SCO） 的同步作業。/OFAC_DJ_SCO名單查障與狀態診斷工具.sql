檔案二：SCO 名單專用查障與診斷工具
當 User 問 「為什麼某家受制裁控股公司在 DJ 是 SCO 名單，但在系統主表查不到？」 時使用。


/*
========================================================================================
腳本名稱：OFAC_DJ_SCO名單查障與狀態診斷工具.sql
主要定位：第 2 段 SCO (GROUPID = 27) 專用客服與單點排查工具 (純查詢無副作用)
說明：
  User 詢問「為什麼某人或某公司屬於 SCO (實質所有權/控制權) 名單，但主表 GROUPID=27 查不到？」時使用。
========================================================================================
*/

-- -------------------------------------------------------------------------------------
-- 設定查詢條件 (支援 姓名/實體名稱 或 EntNum)
-- -------------------------------------------------------------------------------------
DECLARE @QueryName   NVARCHAR(350) = 'GASPROM'; -- 填入欲查詢的公司或人名
DECLARE @QueryEntNum BIGINT        = NULL;      -- 填入 DJ 實體編號 (留 NULL 則不限制)


-- -------------------------------------------------------------------------------------
-- 診斷 1：全局健檢，檢視 SCO 篩選條件與主表狀態 (GROUPID = 27)
-- -------------------------------------------------------------------------------------
SELECT 
    ISNULL(S.EntNum, CAST(T.remark AS BIGINT)) AS EntNum,
    ISNULL(S.SdnName, T.spec_name)             AS PersonOrEntityName,

    -- 1. SCO 來源端過濾條件診斷
    CASE 
        WHEN S.EntNum IS NULL THEN 'DJ 來源無此資料'
        WHEN S.PersonStatus = 'Inactive' THEN '實體狀態為 Inactive，已被排除'
        WHEN S.HasValidSCOCategory = 0 THEN '不屬於 OFAC/EU Majority Owned 或 Control 分類'
        WHEN S.IsOSN = 1 THEN '名稱次類型為 OSN (NameSubType=OSN)，已被排除'
        ELSE '來源端完全符合 SCO 條件'
    END AS SCO_Source_Condition_Status,

    -- 2. 內部主表狀態診斷 (GROUPID = 27)
    CASE 
        WHEN T.spec_name IS NULL THEN '主表 GROUPID=27 完全找不到 (未同步)'
        WHEN T.DInd = 'Y' THEN '主表存在但「已軟刪除停用 (DInd=Y)」'
        WHEN T.DInd = 'N' THEN '主表正常生效中 (DInd=N)'
    END AS Target_Table_Status,

    T.updated_date AS Internal_UpdatedDate,
    T.ADDRESS      AS Internal_SanctionListRef,
    T.creDate      AS Internal_CreateDate,
    T.DelDate      AS Internal_DelDate

FROM (
    SELECT 
        A.EntityId AS EntNum,
        C.SdnName,
        A.PersonStatus,
        CASE 
            WHEN EXISTS (
                SELECT 1 FROM BSADB.dbo.DJ_ListCategory B WITH (NOLOCK)
                WHERE B.EntityId = A.EntityId 
                  AND B.Deleted = 0
                  AND B.Description3 IN (
                    'OFAC Related - Majority Owned',
                    'OFAC Related – Control',
                    'OFAC - Regional Sanctions Related - Majority Owned',
                    'OFAC - Regional Sanctions Related - Control',
                    'EU Related - Majority Owned',
                    'EU Related - Control',
                    'EU - Regional Sanctions Related - Majority Owned',
                    'EU - Regional Sanctions Related – Control'
                  )
            ) THEN 1 ELSE 0 
        END AS HasValidSCOCategory,
        CASE WHEN ISNULL(D.NameSubType, '') = 'OSN' THEN 1 ELSE 0 END AS IsOSN
    FROM BSADB.dbo.DJ_Entity A WITH (NOLOCK)
    JOIN BSADB.dbo.DJ_List_Data_A C WITH (NOLOCK) ON A.EntityId = C.EntNum
    LEFT JOIN BSADB.dbo.DJ_AltName D WITH (NOLOCK) ON C.EntNum = D.EntityId AND C.AltNum = D.AltNameId
    WHERE (@QueryEntNum IS NOT NULL AND A.EntityId = @QueryEntNum)
       OR (@QueryName IS NOT NULL AND C.SdnName LIKE '%' + @QueryName + '%')
) S
FULL OUTER JOIN (
    SELECT *
    FROM BSADB.dbo.OFAC_GLSpec WITH (NOLOCK)
    WHERE GROUPID = 27
      AND (
          (@QueryEntNum IS NOT NULL AND remark = CAST(@QueryEntNum AS VARCHAR(100)))
       OR (@QueryName IS NOT NULL AND spec_name LIKE '%' + @QueryName + '%')
      )
) T ON T.spec_name = S.SdnName AND T.remark = CAST(S.EntNum AS VARCHAR(100));


-- -------------------------------------------------------------------------------------
-- 診斷 2：調閱該實體在 Log 表中的異動歷史 (GROUPID = 27)
-- -------------------------------------------------------------------------------------
SELECT 
    ActionDt,
    CASE ActionCD 
        WHEN '01' THEN '01 - 新增 / 重新啟用'
        WHEN '02' THEN '02 - 資料更新'
        WHEN '03' THEN '03 - 軟刪除 (停用)'
    END AS ActionType,
    ent_num,
    spec_name,
    remark AS EntNum,
    DInd,
    updated_date,
    ADDRESS AS SanctionListRef
FROM BSADB.dbo.OFAC_GLSpec_Log WITH (NOLOCK)
WHERE GROUPID = 27
  AND (
      (@QueryEntNum IS NOT NULL AND remark = CAST(@QueryEntNum AS VARCHAR(100)))
   OR (@QueryName IS NOT NULL AND spec_name LIKE '%' + @QueryName + '%')
  )
ORDER BY ActionDt DESC;
