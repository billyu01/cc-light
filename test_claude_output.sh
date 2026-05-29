#!/bin/bash

# 测试脚本：模拟 Claude Code 的不同输出状态

echo "=== 测试场景 ==="
echo ""
echo "1. 红灯场景 - Claude 正在输出（模拟流式输出）"
echo "2. 黄灯场景 - 等待用户选择"
echo "3. 绿灯场景 - 任务完成"
echo "4. 绿灯场景 - 空闲等待输入"
echo ""
echo "选择测试场景 (1-4): "
read choice

case $choice in
    1)
        echo ""
        echo "🔴 模拟红灯 - Claude 正在输出..."
        echo ""
        for i in {1..20}; do
            echo "正在处理第 $i 步..."
            sleep 0.3
        done
        echo "输出完成"
        ;;
    2)
        echo ""
        echo "🟡 模拟黄灯 - 等待用户选择..."
        echo ""
        echo "我发现以下选项："
        echo ""
        echo "  [1] 使用方案 A - 简单快速"
        echo "  [2] 使用方案 B - 更完善但复杂"
        echo "  [3] 手动指定其他方案"
        echo ""
        echo "你想选择哪个方案？"
        read -p "请输入选项 (1-3): " answer
        echo "你选择了: $answer"
        ;;
    3)
        echo ""
        echo "🟢 模拟绿灯 - 任务完成..."
        echo ""
        echo "✓ 文件已创建: /path/to/file.swift"
        echo "✓ 代码已更新"
        echo "✓ 测试通过"
        echo ""
        echo "任务已完成！"
        ;;
    4)
        echo ""
        echo "🟢 模拟绿灯 - 空闲等待..."
        echo ""
        echo "你好！有什么我可以帮助你的吗？"
        ;;
esac

echo ""
echo "测试结束"
