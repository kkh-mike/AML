-- OFAC_DJ名單查障與狀態診斷工具.sql
-- Tool_Troubleshoot_OFAC_DJ_Sync.sql

/*
========================================================================================
腳本名稱：OFAC_DJ名單查障與狀態診斷工具.sql
主要定位：客服與單點問題排查工具 (純查詢，安全無副作用)
查詢目標：BSADB.dbo.DJ_List_Data_A, BSADB.dbo.OFAC_GLSpec, BSADB.dbo.OFAC_GLSpec_Log

[適用對象]
一線維運人員、客服工程師、系統管理者

[使用時機]
1. User 或業務詢問「為什麼 DJ 名單有此人，但系統查不到？」。
2. 需要釐清某筆名單為何處於停用狀態 (DInd = 'Y')。
3. 需要調閱特定人員過去的異動時間與操作歷程。

[核心功能與診斷區塊]
- 設定查詢條件：填入 @QueryName (姓名模糊比對) 或 @QueryEntNum (DJ實體編號)。
- 診斷 1：全局健檢 (快速判定：非主要姓名/未同步/已軟刪除/正常生效)。
- 診斷 2：深入追查 (展開該實體的名稱屬性、地址、證件、生日明細及 Deleted 標記)。
- 診斷 3：歷程回溯 (調閱 OFAC_GLSpec_Log 的異動時間與動作代碼)。

[注意事項]
本腳本全程為 SELECT 查詢，完全不修改、不寫入任何資料，可隨時依問題個案直接執行。
========================================================================================
*/




-- -------------------------------------------------------------------------------------
-- 設定查詢條件：請填入 User 提供的資訊，支援姓名或 EntNum 單一或複合查詢
-- -------------------------------------------------------------------------------------
DECLARE @QueryName   NVARCHAR(200) = 'VLADIMIR PUTIN'; -- 填入查詢姓名，留空則不限制
DECLARE @QueryEntNum BIGINT        = NULL;             -- 填入 DJ 實體編號，留 NULL 則不限制
DECLARE @GroupId     BIGINT        = 1;                -- 指定查詢的 GroupId


-- -------------------------------------------------------------------------------------
-- 診斷 1：全局健檢，快速比對 DJ 來源表與內部主表狀態
-- -------------------------------------------------------------------------------------
SELECT 
    ISNULL(DJ.EntNum, CAST(T.remark AS BIGINT)) AS EntNum,
    ISNULL(DJ.SdnName, T.spec_name)             AS PersonOrEntityName,
    
    -- DJ 來源表狀態診斷
    CASE 
        WHEN DJ.EntNum IS NULL THEN 'DJ來源表無此資料，請確認是否未載入'
        WHEN DJ.NamePropertyBitCode & 1 = 0 THEN 'DJ有此人但非主要姓名，屬於別名或次要名稱，同步邏輯會排除'
        ELSE 'DJ來源符合主要名單條件'
    END AS DJ_Source_Status,
    
    DJ.NamePropertyBitCode AS DJ_BitCode,
    DJ.UpdatedDate         AS DJ_UpdatedDate,

    -- 內部主表狀態診斷
    CASE 
        WHEN T.spec_name IS NULL THEN '主表完全找不到，尚未同步'
        WHEN T.DInd = 'Y'        THEN '主表存在但已停用或軟刪除，DInd等於Y'
        WHEN T.DInd = 'N'        THEN '主表正常生效中，DInd等於N'
    END AS Internal_Table_Status,

    T.GROUPID         AS Internal_GroupId,
    T.DInd            AS Internal_DInd,
    T.updated_date    AS Internal_UpdatedDate,
    T.creDt           AS Internal_CreateDt,
    T.delDt           AS Internal_DeleteDt,
    T.remark          AS Internal_Remark_EntNum

FROM (
    SELECT EntNum, SdnName, NamePropertyBitCode, UpdatedDate
    FROM BSADB.dbo.DJ_List_Data_A WITH (NOLOCK)
    WHERE (@QueryEntNum IS NOT NULL AND EntNum = @QueryEntNum)
       OR (@QueryName IS NOT NULL AND SdnName LIKE '%' + @QueryName + '%')
) DJ
FULL OUTER JOIN (
    SELECT *
    FROM BSADB.dbo.OFAC_GLSpec WITH (NOLOCK)
    WHERE (@GroupId IS NULL OR GROUPID = @GroupId)
      AND (
          (@QueryEntNum IS NOT NULL AND remark = CAST(@QueryEntNum AS VARCHAR(100)))
       OR (@QueryName IS NOT NULL AND spec_name LIKE '%' + @QueryName + '%')
      )
) T ON T.spec_name = DJ.SdnName AND T.remark = CAST(DJ.EntNum AS VARCHAR(100));


-- -------------------------------------------------------------------------------------
-- 診斷 2：深入追查該人員在 DJ 來源的所有關聯明細
-- -------------------------------------------------------------------------------------

-- 2.1 檢查 DJ 原始主檔，包含別名與所有名稱屬性
SELECT 
    '1. DJ 名稱主檔' AS DataType,
    A.EntNum,
    A.SdnName,
    A.NamePropertyBitCode,
    CASE WHEN A.NamePropertyBitCode & 1 > 0 THEN '是 (Primary)' ELSE '否 (Alias/Other)' END AS IsPrimaryName,
    A.UpdatedDate
FROM BSADB.dbo.DJ_List_Data_A A WITH (NOLOCK)
WHERE (@QueryEntNum IS NOT NULL AND A.EntNum = @QueryEntNum)
   OR (@QueryName IS NOT NULL AND A.SdnName LIKE '%' + @QueryName + '%');

-- 2.2 檢查 DJ 地址明細
SELECT 
    '2. DJ 地址明細' AS DataType,
    A.EntityId AS EntNum,
    A.Id AS AddressId,
    A.Address,
    A.City,
    A.AddressCountry,
    A.Deleted,
    ROW_NUMBER() OVER (PARTITION BY A.EntityId ORDER BY A.Id) AS PriorityRank
FROM BSADB.dbo.DJ_Address A WITH (NOLOCK)
WHERE (@QueryEntNum IS NOT NULL AND A.EntityId = @QueryEntNum)
   OR (@QueryName IS NOT NULL AND EXISTS (
        SELECT 1 FROM BSADB.dbo.DJ_List_Data_A N 
        WHERE N.EntNum = A.EntityId AND N.SdnName LIKE '%' + @QueryName + '%'
   ));

-- 2.3 檢查 DJ 證件明細
SELECT 
    '3. DJ 證件明細' AS DataType,
    A.EntityId AS EntNum,
    A.Id AS IdentId,
    A.IdentificationType,
    A.IdentificationNumber,
    A.Deleted,
    ROW_NUMBER() OVER (PARTITION BY A.EntityId ORDER BY A.Id) AS PriorityRank
FROM BSADB.dbo.DJ_IdentificationTypeInfo A WITH (NOLOCK)
WHERE (@QueryEntNum IS NOT NULL AND A.EntityId = @QueryEntNum)
   OR (@QueryName IS NOT NULL AND EXISTS (
        SELECT 1 FROM BSADB.dbo.DJ_List_Data_A N 
        WHERE N.EntNum = A.EntityId AND N.SdnName LIKE '%' + @QueryName + '%'
   ));

-- 2.4 檢查 DJ 生日明細
SELECT 
    '4. DJ 出生日期' AS DataType,
    A.EntityId AS EntNum,
    A.Id AS DateId,
    A.DateType,
    A.InfoYear,
    A.InfoMonth,
    A.InfoDay,
    A.Deleted,
    ROW_NUMBER() OVER (PARTITION BY A.EntityId ORDER BY A.Id) AS PriorityRank
FROM BSADB.dbo.DJ_DateTypeInfo A WITH (NOLOCK)
WHERE A.DateType = 'Date of Birth'
  AND (
      (@QueryEntNum IS NOT NULL AND A.EntityId = @QueryEntNum)
   OR (@QueryName IS NOT NULL AND EXISTS (
        SELECT 1 FROM BSADB.dbo.DJ_List_Data_A N 
        WHERE N.EntNum = A.EntityId AND N.SdnName LIKE '%' + @QueryName + '%'
   ))
  );


-- -------------------------------------------------------------------------------------
-- 診斷 3：歷程回溯，查詢歷史異動 Log
-- -------------------------------------------------------------------------------------
SELECT 
    L.ActionDt,
    CASE L.ActionCD 
        WHEN '01' THEN '01 - 新增 / 重新啟用'
        WHEN '02' THEN '02 - 資料更新'
        WHEN '03' THEN '03 - 軟刪除 (停用)'
    END AS ActionType,
    L.ent_num,
    L.spec_name,
    L.remark AS DJ_EntNum,
    L.DInd   AS Status_DInd,
    L.GROUPID,
    L.updated_date AS DJ_UpdatedDate_Snapshot
FROM BSADB.dbo.OFAC_GLSpec_Log L WITH (NOLOCK)
WHERE (@GroupId IS NULL OR L.GROUPID = @GroupId)
  AND (
      (@QueryEntNum IS NOT NULL AND L.remark = CAST(@QueryEntNum AS VARCHAR(100)))
   OR (@QueryName IS NOT NULL AND L.spec_name LIKE '%' + @QueryName + '%')
  )
ORDER BY L.ActionDt DESC;
