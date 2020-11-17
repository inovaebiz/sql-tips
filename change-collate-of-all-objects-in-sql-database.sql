/*******************************************************************************
*
* Created 2017-06-16 By Philip C
*
* This script will check individual columns collations and check it against the
* database default collation, where they are different it will create the scripts
* required to drop all the objects dependant on the column, change the collation
* to the database default and then recreate the dependant objects.
* Some of the code has been reused from stuff found online the majority from 
* Jayakumaur R who created scripts to drop and recreate constraints
*
*********************************************************************************/

SET ANSI_WARNINGS OFF;
GO
DECLARE @SchemaName VARCHAR(100);
DECLARE @TableName VARCHAR(256);
DECLARE @IndexName VARCHAR(256);
DECLARE @ColumnName VARCHAR(100);
DECLARE @is_unique VARCHAR(100);
DECLARE @IndexTypeDesc VARCHAR(100);
DECLARE @FileGroupName VARCHAR(100);
DECLARE @is_disabled VARCHAR(100);
DECLARE @IndexOptions VARCHAR(MAX);
DECLARE @IndexColumnId INT;
DECLARE @IsDescendingKey INT;
DECLARE @IsIncludedColumn INT;
DECLARE @TSQLScripCreationIndex VARCHAR(MAX);
DECLARE @TSQLScripDisableIndex VARCHAR(MAX);
DECLARE @Collation_objectid INT;
DECLARE @Collation_columnid INT;
DECLARE @Collation_constraint INT;
DECLARE @Collation_index INT;
DECLARE @Collation_foreign INT;
DECLARE @Collation_stats INT;
DECLARE @stats_id INT;
DECLARE @Collation_fkid INT;
DECLARE @Collation_unique INT;
DECLARE @DatabaseCollation VARCHAR(100);
CREATE TABLE #tempscriptstore (ScriptType VARCHAR(20),
script NVARCHAR(MAX));
SELECT @DatabaseCollation=collation_name
FROM sys.databases
WHERE database_id=DB_ID();

/************************************************************************************************************************************
*   Generates a list of all the columns where their collation doesn't match the database default and the depenmdancies they have.   *
************************************************************************************************************************************/
DECLARE collationfix CURSOR FOR
SELECT t.object_id, c.column_id, COUNT(kc.object_id) AS [has_key_constraint], COUNT(ic.index_id) AS [has_index], COUNT(fk.constraint_object_id) AS [has_foreign_key], COUNT(st.stats_id) AS [has_stats], COUNT(uq.object_id) AS [has_unique_constraint]
FROM sys.columns c
    INNER JOIN sys.tables t ON c.object_id=t.object_id
    INNER JOIN sys.types ty ON c.system_type_id=ty.system_type_id
    LEFT JOIN sys.index_columns ic ON ic.object_id=c.object_id AND ic.column_id=c.column_id
    LEFT JOIN sys.key_constraints kc ON kc.parent_object_id=c.object_id AND kc.unique_index_id=ic.index_id AND kc.type='PK'
    LEFT JOIN sys.key_constraints uq ON uq.parent_object_id=c.object_id AND uq.unique_index_id=ic.index_id AND uq.type='UQ'
    LEFT JOIN sys.foreign_key_columns fk ON fk.referenced_object_id=c.object_id AND fk.constraint_column_id=c.column_id
    LEFT JOIN sys.stats_columns st ON st.object_id=c.object_id AND st.column_id=c.column_id AND st.stats_column_id !=1
WHERE t.is_ms_shipped=0 AND c.collation_name<>@DatabaseCollation AND ty.name !='sysname'
GROUP BY t.object_id, c.column_id;
OPEN collationfix;
FETCH NEXT FROM collationfix
INTO @Collation_objectid, @Collation_columnid, @Collation_constraint, @Collation_index, @Collation_foreign, @Collation_stats, @Collation_unique;
WHILE(@@FETCH_STATUS=0)BEGIN

/************************************************************************************************************************************
*   Generates the code to update the columns colation                                                                               *
************************************************************************************************************************************/
  INSERT INTO #tempscriptstore(ScriptType, script)
  SELECT DISTINCT 'AlterCollation', 'ALTER TABLE '+QUOTENAME(t.name)+' ALTER COLUMN '+QUOTENAME(c.name)+' '+CASE WHEN ty.name='ntext' THEN ty.name+' COLLATE '+@DatabaseCollation+' ' ELSE ty.name+'('+CASE WHEN c.max_length=-1 THEN 'MAX' ELSE CASE WHEN ty.name='nvarchar' THEN CAST(c.max_length / 2 AS VARCHAR(20))ELSE CAST(c.max_length AS VARCHAR(20))END END+') COLLATE '+@DatabaseCollation+' ' END+CASE WHEN c.is_nullable=1 THEN 'NULL;' ELSE 'NOT NULL;' END
  FROM sys.columns c
      INNER JOIN sys.tables t ON c.object_id=t.object_id
      INNER JOIN sys.types ty ON c.system_type_id=ty.system_type_id
      LEFT JOIN sys.index_columns ic ON ic.object_id=c.object_id AND ic.column_id=c.column_id
  WHERE t.is_ms_shipped=0 AND c.collation_name<>@DatabaseCollation AND ty.name !='sysname' AND c.column_id=@Collation_columnid AND t.object_id=@Collation_objectid;

/************************************************************************************************************************************
*   If the column is in an index this creates the drop and recreate index script                                                    *
************************************************************************************************************************************/
  IF @Collation_index>0 BEGIN
    DECLARE CursorIndex CURSOR FOR
    SELECT DISTINCT SCHEMA_NAME(t.schema_id) [schema_name], t.name, ix.name, CASE WHEN ix.is_unique=1 THEN 'UNIQUE ' ELSE '' END, ix.type_desc, CASE WHEN ix.is_padded=1 THEN 'PAD_INDEX = ON, ' ELSE 'PAD_INDEX = OFF, ' END+CASE WHEN ix.allow_page_locks=1 THEN 'ALLOW_PAGE_LOCKS = ON, ' ELSE 'ALLOW_PAGE_LOCKS = OFF, ' END+CASE WHEN ix.allow_row_locks=1 THEN 'ALLOW_ROW_LOCKS = ON, ' ELSE 'ALLOW_ROW_LOCKS = OFF, ' END+CASE WHEN INDEXPROPERTY(t.object_id, ix.name, 'IsStatistics')=1 THEN 'STATISTICS_NORECOMPUTE = ON, ' ELSE 'STATISTICS_NORECOMPUTE = OFF, ' END+CASE WHEN ix.ignore_dup_key=1 THEN 'IGNORE_DUP_KEY = ON, ' ELSE 'IGNORE_DUP_KEY = OFF, ' END+'SORT_IN_TEMPDB = OFF, FILLFACTOR ='+CASE WHEN ix.fill_factor=0 THEN CAST(100 AS VARCHAR(3))ELSE CAST(ix.fill_factor AS VARCHAR(3))END AS IndexOptions, ix.is_disabled, FILEGROUP_NAME(ix.data_space_id) FileGroupName
    FROM sys.tables t
        JOIN sys.indexes ix ON t.object_id=ix.object_id
        JOIN sys.columns c ON c.object_id=t.object_id
        JOIN sys.index_columns ic ON ic.index_id=ix.index_id AND ic.column_id=c.column_id AND ic.object_id=t.object_id
    WHERE ix.type>0 AND ix.is_primary_key=0 AND ix.is_unique_constraint=0
        --AND schema_name(tb.schema_id)= @SchemaName 
        --AND tb.name=@TableName
        AND t.is_ms_shipped=0 AND t.name<>'sysdiagrams' AND c.column_id=@Collation_columnid AND t.object_id=@Collation_objectid AND ic.column_id=@Collation_columnid
    ORDER BY SCHEMA_NAME(t.schema_id), t.name, ix.name;
    OPEN CursorIndex;
    FETCH NEXT FROM CursorIndex
    INTO @SchemaName, @TableName, @IndexName, @is_unique, @IndexTypeDesc, @IndexOptions, @is_disabled, @FileGroupName;
    WHILE(@@fetch_status=0)BEGIN
      DECLARE @IndexColumns VARCHAR(MAX);
      DECLARE @IncludedColumns VARCHAR(MAX);
      SET @IndexColumns='';
      SET @IncludedColumns='';
      DECLARE CursorIndexColumn CURSOR FOR
      SELECT col.name, ixc.is_descending_key, ixc.is_included_column
      FROM sys.tables tb
          INNER JOIN sys.indexes ix ON tb.object_id=ix.object_id
          INNER JOIN sys.index_columns ixc ON ix.object_id=ixc.object_id AND ix.index_id=ixc.index_id
          INNER JOIN sys.columns col ON ixc.object_id=col.object_id AND ixc.column_id=col.column_id
      WHERE ix.type>0 AND(ix.is_primary_key=0 OR ix.is_unique_constraint=0)AND SCHEMA_NAME(tb.schema_id)=@SchemaName AND tb.name=@TableName AND ix.name=@IndexName
      ORDER BY ixc.index_column_id;
      OPEN CursorIndexColumn;
      FETCH NEXT FROM CursorIndexColumn
      INTO @ColumnName, @IsDescendingKey, @IsIncludedColumn;
      WHILE(@@fetch_status=0)BEGIN
        IF @IsIncludedColumn=0
          SET @IndexColumns=@IndexColumns+@ColumnName+CASE WHEN @IsDescendingKey=1 THEN ' DESC, ' ELSE ' ASC, ' END;
        ELSE SET @IncludedColumns=@IncludedColumns+@ColumnName+', ';
        FETCH NEXT FROM CursorIndexColumn
        INTO @ColumnName, @IsDescendingKey, @IsIncludedColumn;
      END;
      CLOSE CursorIndexColumn;
      DEALLOCATE CursorIndexColumn;
      SET @IndexColumns=SUBSTRING(@IndexColumns, 1, LEN(@IndexColumns)-1);
      SET @IncludedColumns=CASE WHEN LEN(@IncludedColumns)>0 THEN SUBSTRING(@IncludedColumns, 1, LEN(@IncludedColumns)-1)ELSE '' END;
      --  print @IndexColumns
      --  print @IncludedColumns
      INSERT INTO #tempscriptstore(ScriptType, script)
      SELECT 'DropIndex', 'DROP INDEX '+QUOTENAME(@SchemaName)+'.'+QUOTENAME(@TableName)+'.'+QUOTENAME(@IndexName)+';';
      INSERT INTO #tempscriptstore(ScriptType, script)
      SELECT 'CreateIndex', 'CREATE '+@is_unique+@IndexTypeDesc+' INDEX '+QUOTENAME(@IndexName)+' ON '+QUOTENAME(@SchemaName)+'.'+QUOTENAME(@TableName)+'('+@IndexColumns+') '+CASE WHEN LEN(@IncludedColumns)>0 THEN CHAR(13)+'INCLUDE ('+@IncludedColumns+')' ELSE '' END+CHAR(13)+'WITH ('+@IndexOptions+') ON '+QUOTENAME(@FileGroupName)+';';
      IF @is_disabled=1
        INSERT INTO #tempscriptstore(ScriptType, script)
        SELECT 'DisableIndex', 'ALTER INDEX '+QUOTENAME(@IndexName)+' ON '+QUOTENAME(@SchemaName)+'.'+QUOTENAME(@TableName)+' DISABLE;';
      FETCH NEXT FROM CursorIndex
      INTO @SchemaName, @TableName, @IndexName, @is_unique, @IndexTypeDesc, @IndexOptions, @is_disabled, @FileGroupName;
    END;
    CLOSE CursorIndex;
    DEALLOCATE CursorIndex;
  END;

/************************************************************************************************************************************
*   If the column has a primary key constraint this creates the drop and recreate constraint script                                 *
*   this has been taken and adapted from a script found online created by Jayakumaur R                                              *
************************************************************************************************************************************/
  IF @Collation_constraint>0 BEGIN
    -------------------------------------------------
    --ALTER TABLE DROP PRIMARY KEY CONSTRAINT Queries
    -------------------------------------------------
    INSERT INTO #tempscriptstore(ScriptType, script)
    SELECT DISTINCT 'DropPrimaryKey', 'ALTER TABLE '+QUOTENAME(OBJECT_SCHEMA_NAME(parent_object_id))+'.'+QUOTENAME(OBJECT_NAME(parent_object_id))+' DROP CONSTRAINT '+QUOTENAME(name)
    FROM sys.key_constraints skc
    WHERE type='PK' AND parent_object_id=@Collation_objectid;

    ---------------------------------------------------
    --ALTER TABLE CREATE PRIMARY KEY CONSTRAINT Queries
    ---------------------------------------------------
    SELECT QUOTENAME(OBJECT_SCHEMA_NAME(parent_object_id))+'.'+QUOTENAME(OBJECT_NAME(parent_object_id)) AS pk_table, --PK table name
      skc.object_id AS constid, QUOTENAME(skc.name) AS constraint_name, --PK name
      QUOTENAME(iskcu.COLUMN_NAME)+CASE WHEN sic.is_descending_key=1 THEN ' DESC' ELSE ' ASC' END AS pk_col, iskcu.ORDINAL_POSITION, CASE WHEN unique_index_id=1 THEN 'UNIQUE' ELSE '' END AS index_unique_type, si.name AS index_name, si.type_desc AS index_type, QUOTENAME(fg.name) AS filegroup_name, 'WITH('+' PAD_INDEX = '+CASE WHEN si.is_padded=0 THEN 'OFF' ELSE 'ON' END+','+' IGNORE_DUP_KEY = '+CASE WHEN si.ignore_dup_key=0 THEN 'OFF' ELSE 'ON' END+','+' ALLOW_ROW_LOCKS = '+CASE WHEN si.allow_row_locks=0 THEN 'OFF' ELSE 'ON' END+','+' ALLOW_PAGE_LOCKS = '+CASE WHEN si.allow_page_locks=0 THEN 'OFF' ELSE 'ON' END+')' AS index_property
    --,*
    INTO #temp_pk
    FROM sys.key_constraints skc
        INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE iskcu ON skc.name=iskcu.CONSTRAINT_NAME
        INNER JOIN sys.indexes si ON si.object_id=skc.parent_object_id AND si.is_primary_key=1
        INNER JOIN sys.index_columns sic ON si.object_id=sic.object_id AND si.index_id=sic.index_id
        INNER JOIN sys.columns c ON sic.object_id=c.object_id AND sic.column_id=c.column_id
        INNER JOIN sys.filegroups fg ON si.data_space_id=fg.data_space_id
    WHERE skc.type='PK' AND iskcu.COLUMN_NAME=c.name AND skc.parent_object_id=@Collation_objectid
    ORDER BY skc.parent_object_id, skc.name, ORDINAL_POSITION;
    WITH cte AS (SELECT pk_table, constraint_name, index_type, SUBSTRING((SELECT ','+pk_col FROM #temp_pk WHERE constid=t.constid FOR XML PATH('')), 2, 99999) AS pk_col_list, index_unique_type, filegroup_name, index_property
            FROM #temp_pk t)
    --forming the ADD CONSTRAINT query
    INSERT INTO #tempscriptstore(ScriptType, script)
    SELECT DISTINCT 'AddPrimaryKey', 'ALTER TABLE '+pk_table+' ADD CONSTRAINT '+constraint_name+' PRIMARY KEY '+CAST(index_type COLLATE DATABASE_DEFAULT AS VARCHAR(100))+' ('+pk_col_list+')'+index_property+' ON '+filegroup_name+''
    FROM cte;

    --dropping the temp tables
    DROP TABLE #temp_pk;
  END;

/************************************************************************************************************************************
*   If the column has a foreign key constraint this creates the drop and recreate constraint script                                 *
*   this has been taken and adapted from a script found online cretaed by Jayakumaur R                                              *
************************************************************************************************************************************/
  IF @Collation_foreign>0 BEGIN
    DECLARE foreignkeycursor CURSOR FOR
    SELECT constraint_object_id
    FROM sys.foreign_key_columns
    WHERE referenced_object_id=@Collation_objectid AND referenced_column_id=@Collation_columnid;
    OPEN foreignkeycursor;
    FETCH NEXT FROM foreignkeycursor
    INTO @Collation_fkid;
    WHILE(@@FETCH_STATUS=0)BEGIN

      ---------------------------------------------
      --ALTER TABLE DROP FOREIGN CONSTRAINT Queries
      ---------------------------------------------
      INSERT INTO #tempscriptstore(ScriptType, script)
      SELECT DISTINCT 'DropForeignKey', 'ALTER TABLE '+QUOTENAME(OBJECT_SCHEMA_NAME(fkeyid))+'.'+QUOTENAME(OBJECT_NAME(fkeyid))+' DROP CONSTRAINT '+QUOTENAME(OBJECT_NAME(constid))
      FROM sys.sysforeignkeys sfk
      WHERE sfk.constid=@Collation_fkid;

      ------------------------------------------------
      --ALTER TABLE CREATE FOREIGN CONSTRAINT Queries
      ------------------------------------------------

      --Obtaining the necessary info from the sys tables
      SELECT constid, QUOTENAME(OBJECT_NAME(constid)) AS constraint_name, CASE WHEN fk.is_not_trusted=1 THEN 'WITH NOCHECK' ELSE 'WITH CHECK' END AS trusted_status, QUOTENAME(OBJECT_SCHEMA_NAME(fkeyid))+'.'+QUOTENAME(OBJECT_NAME(fkeyid)) AS fk_table, QUOTENAME(c1.name) AS fk_col, QUOTENAME(OBJECT_SCHEMA_NAME(rkeyid))+'.'+QUOTENAME(OBJECT_NAME(rkeyid)) AS rk_table, QUOTENAME(c2.name) AS rk_col, CASE WHEN fk.delete_referential_action=1 AND fk.delete_referential_action_desc='CASCADE' THEN 'ON DELETE CASCADE ' ELSE '' END AS delete_cascade, CASE WHEN fk.update_referential_action=1 AND fk.update_referential_action_desc='CASCADE' THEN 'ON UPDATE CASCADE ' ELSE '' END AS update_cascade, CASE WHEN fk.is_disabled=1 THEN 'NOCHECK' ELSE 'CHECK' END AS check_status
      --,sysfk.*,fk.* 
      INTO #temp_fk
      FROM sys.sysforeignkeys sysfk
          INNER JOIN sys.foreign_keys fk ON sysfk.constid=fk.object_id
          INNER JOIN sys.columns c1 ON sysfk.fkeyid=c1.object_id AND sysfk.fkey=c1.column_id
          INNER JOIN sys.columns c2 ON sysfk.rkeyid=c2.object_id AND sysfk.rkey=c2.column_id
      WHERE sysfk.constid=@Collation_fkid
      ORDER BY constid, sysfk.keyno

      --building the column list for foreign/primary key tables
      ;
      WITH cte AS (SELECT DISTINCT constraint_name, trusted_status, fk_table, SUBSTRING((SELECT ','+fk_col FROM #temp_fk WHERE constid=c.constid FOR XML PATH('')), 2, 99999) AS fk_col_list, rk_table, SUBSTRING((SELECT ','+rk_col FROM #temp_fk WHERE constid=c.constid FOR XML PATH('')), 2, 99999) AS rk_col_list, check_status, delete_cascade, update_cascade
              FROM #temp_fk c)
      --forming the ADD CONSTRAINT query
      INSERT INTO #tempscriptstore(ScriptType, script)
      SELECT DISTINCT 'AddForeignKey', 'ALTER TABLE '+fk_table+' '+trusted_status+' ADD CONSTRAINT '+constraint_name+' FOREIGN KEY('+fk_col_list+') REFERENCES '+rk_table+'('+rk_col_list+')'+' '+delete_cascade+update_cascade+';'+' ALTER TABLE '+fk_table+' '+check_status+' CONSTRAINT '+constraint_name
      FROM cte;

      --dropping the temp tables
      DROP TABLE #temp_fk;
      FETCH NEXT FROM foreignkeycursor
      INTO @Collation_fkid;
    END;
    CLOSE foreignkeycursor;
    DEALLOCATE foreignkeycursor;
  END;

/************************************************************************************************************************************
*   If the column has statistics that aren't part of an index this creates the drop and recreate scripts                                *
************************************************************************************************************************************/
  IF @Collation_stats>0 AND @Collation_index=0 BEGIN
    DECLARE stats_cursor CURSOR FOR
    SELECT sc.stats_id
    FROM sys.stats_columns sc
        JOIN sys.stats s ON s.object_id=sc.object_id AND s.stats_id=sc.stats_id AND s.user_created=1
    WHERE sc.object_id=@Collation_objectid AND sc.column_id=@Collation_columnid;
    OPEN stats_cursor;
    FETCH NEXT FROM stats_cursor
    INTO @stats_id;
    WHILE(@@FETCH_STATUS=0)BEGIN
      --Create DROP Statistics Statement
      INSERT INTO #tempscriptstore(ScriptType, script)
      SELECT 'DropStatistics', 'DROP STATISTICS '+QUOTENAME(OBJECT_SCHEMA_NAME(s.object_id))+'.'+QUOTENAME(OBJECT_NAME(s.object_id))+'.'+QUOTENAME(s.name)
      FROM sys.stats s
      WHERE s.object_id=@Collation_objectid AND s.stats_id=@stats_id;

      --Building the CREATE statistics statement

      --Obtaining all the information
      SELECT QUOTENAME(OBJECT_SCHEMA_NAME(sc.object_id))+'.'+QUOTENAME(OBJECT_NAME(sc.object_id)) AS st_table, QUOTENAME(s.name) AS st_name, QUOTENAME(c.name) AS st_column, sc.object_id, sc.stats_id, sc.stats_column_id
      INTO #temp_stats
      FROM sys.stats_columns sc
          JOIN sys.stats s ON s.stats_id=sc.stats_id AND s.object_id=sc.object_id
          JOIN sys.columns c ON c.object_id=sc.object_id AND c.column_id=sc.column_id
      WHERE sc.object_id=@Collation_objectid AND sc.stats_id=@stats_id;
      WITH cte AS (SELECT DISTINCT st_table, st_name, SUBSTRING((SELECT ','+st_column
                                      FROM #temp_stats
                                      WHERE stats_id=ts.stats_id
                                      ORDER BY stats_column_id ASC
                                    FOR XML PATH('')), 2, 99999) AS st_col_list
              FROM #temp_stats ts)
      --Constructing the statement
      INSERT INTO #tempscriptstore(ScriptType, script)
      SELECT 'AddStatistics', 'CREATE STATISTICS '+cte.st_name+' ON '+cte.st_table+'('+cte.st_col_list+')'
      FROM cte;
      DROP TABLE #temp_stats;
      FETCH NEXT FROM stats_cursor
      INTO @stats_id;
    END;
    CLOSE stats_cursor;
    DEALLOCATE stats_cursor;
  END;

/************************************************************************************************************************************
*   If the column has a unique constraint this creates the drop and recreate scripts                                                *
************************************************************************************************************************************/
  IF @Collation_unique>0 BEGIN

    -------------------------------------------------
    --ALTER TABLE DROP UNIQUE CONSTRAINT Queries
    -------------------------------------------------
    INSERT INTO #tempscriptstore(ScriptType, script)
    SELECT DISTINCT 'DropUniqueKey', 'ALTER TABLE '+QUOTENAME(OBJECT_SCHEMA_NAME(parent_object_id))+'.'+QUOTENAME(OBJECT_NAME(parent_object_id))+' DROP CONSTRAINT '+QUOTENAME(name)
    FROM sys.key_constraints skc
        JOIN sys.index_columns ic ON ic.object_id=skc.parent_object_id AND ic.index_id=skc.unique_index_id
    WHERE type='UQ' AND parent_object_id=@Collation_objectid AND ic.column_id=@Collation_columnid;

    ---------------------------------------------------
    --ALTER TABLE CREATE UNIQUE CONSTRAINT Queries
    ---------------------------------------------------
    SELECT QUOTENAME(OBJECT_SCHEMA_NAME(parent_object_id))+'.'+QUOTENAME(OBJECT_NAME(parent_object_id)) AS uq_table, --PK table name
      skc.object_id AS constid, QUOTENAME(skc.name) AS constraint_name, --PK name
      QUOTENAME(iskcu.COLUMN_NAME)+CASE WHEN sic.is_descending_key=1 THEN ' DESC' ELSE ' ASC' END AS uq_col, iskcu.ORDINAL_POSITION, CASE WHEN unique_index_id=1 THEN 'UNIQUE' ELSE '' END AS index_unique_type, si.name AS index_name, si.type_desc AS index_type, QUOTENAME(fg.name) AS filegroup_name, 'WITH('+' PAD_INDEX = '+CASE WHEN si.is_padded=0 THEN 'OFF' ELSE 'ON' END+','+' IGNORE_DUP_KEY = '+CASE WHEN si.ignore_dup_key=0 THEN 'OFF' ELSE 'ON' END+','+' ALLOW_ROW_LOCKS = '+CASE WHEN si.allow_row_locks=0 THEN 'OFF' ELSE 'ON' END+','+' ALLOW_PAGE_LOCKS = '+CASE WHEN si.allow_page_locks=0 THEN 'OFF' ELSE 'ON' END+')' AS index_property
    --,*
    INTO #temp_uq
    FROM sys.key_constraints skc
        INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE iskcu ON skc.name=iskcu.CONSTRAINT_NAME
        INNER JOIN sys.indexes si ON si.object_id=skc.parent_object_id AND si.is_unique=1
        INNER JOIN sys.index_columns sic ON si.object_id=sic.object_id AND si.index_id=sic.index_id
        INNER JOIN sys.columns c ON sic.object_id=c.object_id AND sic.column_id=c.column_id
        INNER JOIN sys.filegroups fg ON si.data_space_id=fg.data_space_id
    WHERE skc.type='UQ' AND iskcu.COLUMN_NAME=c.name AND skc.parent_object_id=@Collation_objectid AND c.column_id=@Collation_columnid
    ORDER BY skc.parent_object_id, skc.name, ORDINAL_POSITION;
    WITH cte AS (SELECT uq_table, constraint_name, index_type, SUBSTRING((SELECT ','+uq_col FROM #temp_uq WHERE constid=t.constid FOR XML PATH('')), 2, 99999) AS uq_col_list, index_unique_type, filegroup_name, index_property
            FROM #temp_uq t)
    --forming the ADD CONSTRAINT query
    INSERT INTO #tempscriptstore(ScriptType, script)
    SELECT DISTINCT 'AddUniqueKey', 'ALTER TABLE '+uq_table+' ADD CONSTRAINT '+constraint_name+' UNIQUE '+CAST(index_type COLLATE DATABASE_DEFAULT AS VARCHAR(100))+' ('+uq_col_list+')'+index_property+' ON '+filegroup_name+''
    FROM cte;

    --dropping the temp tables
    DROP TABLE #temp_uq;
  END;
  FETCH NEXT FROM collationfix
  INTO @Collation_objectid, @Collation_columnid, @Collation_constraint, @Collation_index, @Collation_foreign, @Collation_stats, @Collation_unique;
END;
CLOSE collationfix;
DEALLOCATE collationfix;

/************************************************************************************************************************************
*   Returns all the created scripts in the correct order for running                                                                *
************************************************************************************************************************************/
SELECT DISTINCT script, CASE WHEN ScriptType='DropForeignKey' THEN 1
            WHEN ScriptType='DropPrimaryKey' THEN 2
            WHEN ScriptType='DropUniqueKey' THEN 3
            WHEN ScriptType='DropIndex' THEN 4
            WHEN ScriptType='DropStatistics' THEN 5
            WHEN ScriptType='AlterCollation' THEN 6
            WHEN ScriptType='CreateIndex' THEN 7
            WHEN ScriptType='DisableIndex' THEN 8
            WHEN ScriptType='AddStatistics' THEN 9
            WHEN ScriptType='AddUniqueKey' THEN 10
            WHEN ScriptType='AddPrimaryKey' THEN 11
            WHEN ScriptType='AddForeignKey' THEN 12 ELSE 99 END AS [exec_order]
FROM #tempscriptstore
WHERE script !=''
ORDER BY exec_order ASC;
DROP TABLE #tempscriptstore;
